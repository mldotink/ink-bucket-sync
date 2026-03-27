#!/bin/bash
set -euo pipefail

SYNC_PATH="${SYNC_PATH:-/data}"
SYNC_INTERVAL="${SYNC_INTERVAL:-5}"
SYNC_MODE="${SYNC_MODE:-bidirectional}"
PROVIDER="${BUCKET_PROVIDER:-gcs}"
WATCHDOG_ENABLED="${WATCHDOG_ENABLED:-true}"
WATCHDOG_DEBOUNCE="${WATCHDOG_DEBOUNCE:-1}"

mkdir -p "${SYNC_PATH}" /tmp/rclone

RCLONE_CONF="/tmp/rclone/rclone.conf"
LOCK_DIR="/tmp/.bisync-lock"
LAST_SYNC_EPOCH=0
WATCH_PID=""

require_env() {
  local var_name="${1}"
  if [ -z "${!var_name:-}" ]; then
    echo "Missing required environment variable: ${var_name}" >&2
    exit 1
  fi
}

build_remote() {
  local base="${1%/}"
  local prefix="${2:-}"

  if [ -n "${prefix}" ]; then
    prefix="${prefix#/}"
    printf 'remote:%s/%s' "${base}" "${prefix}"
  else
    printf 'remote:%s' "${base}"
  fi
}

case "${PROVIDER}" in
  gcs)
    require_env BUCKET_CREDENTIALS
    require_env BUCKET_NAME
    echo "${BUCKET_CREDENTIALS}" | base64 -d > /tmp/rclone/sa.json
    cat > "${RCLONE_CONF}" <<EOF
[remote]
type = google cloud storage
service_account_file = /tmp/rclone/sa.json
bucket_policy_only = true
EOF
    REMOTE="$(build_remote "${BUCKET_NAME}" "${BUCKET_PREFIX:-}")"
    ;;
  s3)
    require_env BUCKET_CREDENTIALS
    require_env BUCKET_NAME
    IFS=':' read -r ACCESS_KEY SECRET_KEY <<< "${BUCKET_CREDENTIALS}"
    if [ -z "${ACCESS_KEY:-}" ] || [ -z "${SECRET_KEY:-}" ]; then
      echo "BUCKET_CREDENTIALS for s3 must be ACCESS_KEY:SECRET_KEY" >&2
      exit 1
    fi
    S3_PROVIDER="Other"
    if [ -z "${BUCKET_ENDPOINT:-}" ]; then
      S3_PROVIDER="AWS"
    fi
    cat > "${RCLONE_CONF}" <<EOF
[remote]
type = s3
provider = ${S3_PROVIDER}
access_key_id = ${ACCESS_KEY}
secret_access_key = ${SECRET_KEY}
region = ${BUCKET_REGION:-}
endpoint = ${BUCKET_ENDPOINT:-}
no_check_bucket = true
EOF
    REMOTE="$(build_remote "${BUCKET_NAME}" "${BUCKET_PREFIX:-}")"
    ;;
  azure)
    require_env BUCKET_CREDENTIALS
    require_env BUCKET_NAME
    IFS=':' read -r ACCOUNT_NAME ACCOUNT_KEY <<< "${BUCKET_CREDENTIALS}"
    if [ -z "${ACCOUNT_NAME:-}" ] || [ -z "${ACCOUNT_KEY:-}" ]; then
      echo "BUCKET_CREDENTIALS for azure must be ACCOUNT_NAME:ACCOUNT_KEY" >&2
      exit 1
    fi
    cat > "${RCLONE_CONF}" <<EOF
[remote]
type = azureblob
account = ${ACCOUNT_NAME}
key = ${ACCOUNT_KEY}
EOF
    REMOTE="$(build_remote "${BUCKET_NAME}" "${BUCKET_PREFIX:-}")"
    ;;
  local)
    LOCAL_PATH="${BUCKET_PATH:-${BUCKET_NAME:-}}"
    if [ -z "${LOCAL_PATH}" ]; then
      echo "Set BUCKET_PATH (or BUCKET_NAME) for local provider" >&2
      exit 1
    fi
    cat > "${RCLONE_CONF}" <<EOF
[remote]
type = local
EOF
    REMOTE="$(build_remote "${LOCAL_PATH}" "${BUCKET_PREFIX:-}")"
    ;;
  *)
    echo "Unknown provider: ${PROVIDER} (supported: gcs, s3, azure, local)" >&2
    exit 1
    ;;
esac

EXCLUDE_FLAGS=(
  --exclude "node_modules/**"
  --exclude ".venv/**"
  --exclude "__pycache__/**"
  --exclude ".git/**"
  --exclude ".next/**"
  --exclude ".nuxt/**"
  --exclude "dist/**"
  --exclude "coverage/**"
  --exclude ".cache/**"
  --exclude "tmp/**"
  --exclude ".env"
  --exclude ".env.local"
  --exclude ".env.production"
  --exclude "*.pyc"
  --exclude "*.log"
)
WATCH_EXCLUDE_REGEX='(^|/)(node_modules|\.venv|__pycache__|\.git|\.next|\.nuxt|dist|coverage|\.cache|tmp)(/|$)|\.pyc$|\.log$|(^|/)\.env(\..*)?$'

RCLONE_CMD=(rclone "--config=${RCLONE_CONF}")

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [sync] $*"; }

run_upload_copy() {
  if ! "${RCLONE_CMD[@]}" copy "${SYNC_PATH}" "${REMOTE}" "${EXCLUDE_FLAGS[@]}" --quiet 2>&1; then
    log "Sync error (will retry)"
  fi
}

run_bisync_once() {
  local reason="${1}"
  local use_resync="${2:-false}"
  local force_run="${3:-false}"
  local now
  now="$(date +%s)"

  if [ "${force_run}" != "true" ] && [ $((now - LAST_SYNC_EPOCH)) -lt "${WATCHDOG_DEBOUNCE}" ]; then
    return 0
  fi

  if [ "${force_run}" = "true" ]; then
    rmdir "${LOCK_DIR}" 2>/dev/null || true
  fi

  if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    return 0
  fi

  local -a bisync_extra_flags=()
  if [ "${use_resync}" = "true" ]; then
    bisync_extra_flags+=(--resync)
  fi

  log "Running bidirectional sync (${reason})"
  if "${RCLONE_CMD[@]}" bisync "${SYNC_PATH}" "${REMOTE}" "${EXCLUDE_FLAGS[@]}" "${bisync_extra_flags[@]}" --quiet 2>&1; then
    LAST_SYNC_EPOCH="${now}"
  else
    log "Bidirectional sync failed (will retry)"
  fi

  rmdir "${LOCK_DIR}" 2>/dev/null || true
}

watch_local_changes() {
  while true; do
    if inotifywait -qq -r -e create,modify,delete,move,attrib --exclude "${WATCH_EXCLUDE_REGEX}" "${SYNC_PATH}"; then
      sleep "${WATCHDOG_DEBOUNCE}" &
      wait $!
      run_bisync_once "watchdog"
    else
      log "Watchdog wait failed; retrying in 1s"
      sleep 1 &
      wait $!
    fi
  done
}

final_sync() {
  if [ -n "${WATCH_PID}" ]; then
    kill "${WATCH_PID}" 2>/dev/null || true
    wait "${WATCH_PID}" 2>/dev/null || true
  fi

  if [ "${SYNC_MODE}" = "bidirectional" ]; then
    run_bisync_once "shutdown" "false" "true"
  elif [ "${SYNC_MODE}" != "readonly" ]; then
    log "Final sync before exit"
    if ! "${RCLONE_CMD[@]}" copy "${SYNC_PATH}" "${REMOTE}" "${EXCLUDE_FLAGS[@]}" --quiet 2>&1; then
      log "Final sync error"
    fi
  fi
  exit 0
}

trap final_sync SIGTERM SIGINT

case "${SYNC_MODE}" in
  readonly)
    log "Initial sync from ${REMOTE} → ${SYNC_PATH} (readonly)"
    if ! "${RCLONE_CMD[@]}" sync "${REMOTE}" "${SYNC_PATH}" "${EXCLUDE_FLAGS[@]}" --quiet 2>&1; then
      log "Initial sync failed (bucket may be empty)"
    fi
    touch /tmp/.sync-ready
    log "Ready (readonly mode)"
    sleep infinity &
    wait $!
    ;;
  sync)
    touch /tmp/.sync-ready
    log "Starting upload sync loop (every ${SYNC_INTERVAL}s)"
    while true; do
      sleep "${SYNC_INTERVAL}" &
      wait $!
      run_upload_copy
    done
    ;;
  bidirectional)
    run_bisync_once "initial-resync" "true" "true"
    touch /tmp/.sync-ready

    if [ "${WATCHDOG_ENABLED}" = "true" ] && command -v inotifywait >/dev/null 2>&1; then
      log "Starting local watchdog"
      watch_local_changes &
      WATCH_PID=$!
    else
      log "Watchdog disabled or unavailable; relying on polling only"
    fi

    log "Starting bidirectional poll loop (every ${SYNC_INTERVAL}s)"
    while true; do
      sleep "${SYNC_INTERVAL}" &
      wait $!
      run_bisync_once "poll"
    done
    ;;
  *)
    log "Unknown sync mode: ${SYNC_MODE}"
    exit 1
    ;;
esac
