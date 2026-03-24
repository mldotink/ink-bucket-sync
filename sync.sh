#!/bin/bash
set -euo pipefail

SYNC_PATH="${SYNC_PATH:-/data}"
SYNC_INTERVAL="${SYNC_INTERVAL:-5}"
SYNC_MODE="${SYNC_MODE:-bidirectional}"
PROVIDER="${BUCKET_PROVIDER:-gcs}"

mkdir -p "${SYNC_PATH}" /tmp/rclone

RCLONE_CONF="/tmp/rclone/rclone.conf"
case "${PROVIDER}" in
  gcs)
    echo "${BUCKET_CREDENTIALS}" | base64 -d > /tmp/rclone/sa.json
    cat > "${RCLONE_CONF}" <<EOF
[remote]
type = google cloud storage
service_account_file = /tmp/rclone/sa.json
bucket_policy_only = true
EOF
    ;;
  s3)
    IFS=':' read -r ACCESS_KEY SECRET_KEY <<< "${BUCKET_CREDENTIALS}"
    cat > "${RCLONE_CONF}" <<EOF
[remote]
type = s3
provider = Other
access_key_id = ${ACCESS_KEY}
secret_access_key = ${SECRET_KEY}
endpoint = ${BUCKET_ENDPOINT:-}
no_check_bucket = true
EOF
    ;;
  azure)
    IFS=':' read -r ACCOUNT_NAME ACCOUNT_KEY <<< "${BUCKET_CREDENTIALS}"
    cat > "${RCLONE_CONF}" <<EOF
[remote]
type = azureblob
account = ${ACCOUNT_NAME}
key = ${ACCOUNT_KEY}
EOF
    ;;
  *)
    echo "Unknown provider: ${PROVIDER}" >&2
    exit 1
    ;;
esac

REMOTE="remote:${BUCKET_NAME}/${BUCKET_PREFIX:-}"

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

RCLONE="rclone --config=${RCLONE_CONF}"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [sync] $*"; }

final_sync() {
  if [ "${SYNC_MODE}" != "readonly" ]; then
    log "Final sync before exit"
    ${RCLONE} sync "${SYNC_PATH}" "${REMOTE}" "${EXCLUDE_FLAGS[@]}" --quiet 2>&1 || log "Final sync error"
  fi
  exit 0
}
trap final_sync SIGTERM SIGINT

case "${SYNC_MODE}" in
  readonly)
    log "Initial sync from ${REMOTE} → ${SYNC_PATH} (readonly)"
    ${RCLONE} sync "${REMOTE}" "${SYNC_PATH}" "${EXCLUDE_FLAGS[@]}" --quiet 2>&1 || log "Initial sync failed (bucket may be empty)"
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
      ${RCLONE} sync "${SYNC_PATH}" "${REMOTE}" "${EXCLUDE_FLAGS[@]}" --quiet 2>&1 || log "Sync error (will retry)"
    done
    ;;
  bidirectional)
    log "Initial sync from ${REMOTE} → ${SYNC_PATH}"
    ${RCLONE} sync "${REMOTE}" "${SYNC_PATH}" "${EXCLUDE_FLAGS[@]}" --quiet 2>&1 || log "Initial sync failed (bucket may be empty)"
    touch /tmp/.sync-ready
    log "Starting bidirectional sync loop (every ${SYNC_INTERVAL}s)"
    while true; do
      sleep "${SYNC_INTERVAL}" &
      wait $!
      ${RCLONE} sync "${SYNC_PATH}" "${REMOTE}" "${EXCLUDE_FLAGS[@]}" --quiet 2>&1 || log "Sync error (will retry)"
    done
    ;;
  *)
    log "Unknown sync mode: ${SYNC_MODE}"
    exit 1
    ;;
esac
