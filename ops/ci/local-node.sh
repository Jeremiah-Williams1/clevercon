#!/usr/bin/env bash
# Start a local Stellar network (the quickstart image) and wait until it is ready.
# One port serves everything: Horizon at /, Soroban RPC at /rpc, friendbot at /friendbot.
# Network passphrase: "Standalone Network ; February 2017". Throwaway: nothing is stored.
set -euo pipefail

IMAGE="${QUICKSTART_IMAGE:-stellar/quickstart:latest}" # TODO: pin by digest after the first green run
NAME="${NODE_NAME:-clevercon-local-node}"
PORT="${NODE_PORT:-8000}"
WAIT_SECONDS="${NODE_WAIT_SECONDS:-300}"

docker rm -f "$NAME" >/dev/null 2>&1 || true
echo "starting $IMAGE as $NAME on 127.0.0.1:${PORT}"
# --limits testnet: use Testnet's contract size and resource limits, so what deploys here deploys there.
docker run -d --name "$NAME" -p "127.0.0.1:${PORT}:8000" "$IMAGE" --local --limits testnet >/dev/null

rpc_healthy() {
  curl -fsS -m 5 -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}' \
    "http://127.0.0.1:${PORT}/rpc" 2>/dev/null | grep -q '"healthy"'
}
horizon_ready() {
  curl -fsS -m 5 "http://127.0.0.1:${PORT}/" 2>/dev/null | grep -qE '"(core|history)_latest_ledger"'
}
friendbot_up() {
  # Without ?addr= a running friendbot answers 400. 000/404/502/503 mean it is not there yet.
  local code
  code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/friendbot" || true)"
  case "$code" in 000 | 404 | 502 | 503) return 1 ;; *) return 0 ;; esac
}

deadline=$(($(date +%s) + WAIT_SECONDS))
until rpc_healthy && horizon_ready && friendbot_up; do
  if [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || echo false)" != true ]; then
    echo "the container stopped before it was ready:" >&2
    docker logs --tail 80 "$NAME" >&2 || true
    exit 1
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "not ready after ${WAIT_SECONDS}s (rpc/horizon/friendbot); last log lines:" >&2
    docker logs --tail 80 "$NAME" >&2 || true
    exit 1
  fi
  sleep 5
done
echo "local network ready: rpc, horizon and friendbot answer on port ${PORT}"