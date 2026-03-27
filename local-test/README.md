# Local Test (Quick)

Run from `local-test/`.

## 1) Start

```bash
docker compose up --build
```

Leave this terminal running.

## 2) Test bidirectional sync

Open a second terminal in `local-test/` and run:

```bash
echo "from-local" > local-path/from-local.txt
echo "from-remote" > remote-path/from-remote.txt
sleep 5
ls -la local-path
ls -la remote-path
```

Expected:

- `remote-path/from-local.txt` exists
- `local-path/from-remote.txt` exists

If both files appear on the opposite side, sync is working.

## 3) Stop

```bash
docker compose down
```
