#!/usr/bin/env bash
# Build and start api, workers and indexer against the local chain, then wait for /health.
# Needs: Postgres and Redis on 127.0.0.1, local-node.sh, tls-proxy.sh and deploy-local.sh already run.
set -euo pipefail
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

OUT="$(pwd)/${OUT_DIR:-.ci-out}"
NODE_PORT="${NODE_PORT:-8000}"
TLS_PORT="${TLS_PORT:-8443}"
API_PORT="${API_PORT:-4100}"
[ -s "$OUT/chain.env" ] || { echo "run deploy-local.sh first" >&2; exit 1; }

# Read chain.env as plain KEY=VALUE lines (never source it).
while IFS='=' read -r k v; do
  [ -n "$k" ] || continue
  v="${v#\"}"
  v="${v%\"}"
  export "$k=$v"
done < "$OUT/chain.env"

# His services need an https RPC and Horizon URL (F29): use the proxy.
export STELLAR_RPC_URL="https://127.0.0.1:${TLS_PORT}/rpc"
export HORIZON_URL="https://127.0.0.1:${TLS_PORT}"

export NODE_ENV=production NETWORK=testnet BACKEND=full TRUST_PROXY=0 LOG_LEVEL=info
export API_PORT HOME_DOMAIN=localhost WEB_AUTH_DOMAIN=localhost CORS_ORIGINS=http://localhost:5173
export DATABASE_URL="${DATABASE_URL:-postgresql://clevercon:clevercon@127.0.0.1:5432/clevercon}"
export REDIS_URL="${REDIS_URL:-redis://127.0.0.1:6379}"
JWT_SECRET="$(openssl rand -hex 32)"
DELEGATE_ENCRYPTION_KEY="$(openssl rand -hex 32)"
export JWT_SECRET DELEGATE_ENCRYPTION_KEY

echo "== build"
npm run build -w @clevercon/agent-sdk
npm run build -w @clevercon/api

echo "== database"
npx prisma db push --skip-generate --schema packages/db/prisma/schema.prisma
npm run db:seed

# Only the services get the CA and the friendbot redirect.
export NODE_EXTRA_CA_CERTS="$OUT/tls/cert.pem"
export LOCAL_FRIENDBOT_URL="http://127.0.0.1:${NODE_PORT}/friendbot"
ROOT="$(pwd)"
export NODE_OPTIONS="--import=${ROOT}/ops/ci/friendbot-redirect.mjs"

mkdir -p "$OUT/logs"
echo "== start"
nohup node services/api/dist/src/main.js > "$OUT/logs/api.log" 2>&1 &
echo $! > "$OUT/api.pid"
nohup node --import tsx services/workers/src/index.ts > "$OUT/logs/workers.log" 2>&1 &
echo $! > "$OUT/workers.pid"
nohup node --import tsx services/indexer/src/index.ts > "$OUT/logs/indexer.log" 2>&1 &
echo $! > "$OUT/indexer.pid"

ok=0
for _ in $(seq 1 60); do
  if curl -fsS -m 3 "http://127.0.0.1:${API_PORT}/health" >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done

dump() { for s in api workers indexer; do echo "--- $s.log (tail)"; tail -n 40 "$OUT/logs/$s.log" || true; done; }
if [ "$ok" != 1 ]; then
  echo "the api did not become healthy" >&2
  dump >&2
  exit 1
fi
sleep 5
for s in api workers indexer; do
  if ! kill -0 "$(cat "$OUT/$s.pid")" 2>/dev/null; then
    echo "$s exited" >&2
    dump >&2
    exit 1
  fi
done
echo "api, workers and indexer are running (api healthy on ${API_PORT})"