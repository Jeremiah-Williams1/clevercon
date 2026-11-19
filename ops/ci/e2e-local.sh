#!/usr/bin/env bash
# Run his scripts/e2e-testnet.ts against the local chain and the services from start-services.sh.
# His file is not edited: a patched copy is run, and the run stops if upstream changes the lines
# we patch. Same approach as ops/staging/e2e.sh on infra/staging ("core" mode).
#   6 edits: skip the stages that need the retired POST /payments route
#   3 edits: Testnet constants (Horizon URL, USDC issuer, passphrase) come from the environment
# The friendbot calls are redirected by friendbot-redirect.mjs, so they need no patch.
set -euo pipefail
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

ROOT="$(pwd)"
OUT="${ROOT}/${OUT_DIR:-.ci-out}"
NODE_PORT="${NODE_PORT:-8000}"
TLS_PORT="${TLS_PORT:-8443}"
API_PORT="${API_PORT:-4100}"
[ -s "$OUT/chain.env" ] && [ -s "$OUT/keys.env" ] || { echo "run deploy-local.sh first" >&2; exit 1; }

# Read chain.env as plain KEY=VALUE lines (never source it).
while IFS='=' read -r k v; do
  [ -n "$k" ] || continue
  v="${v#\"}"
  v="${v%\"}"
  export "$k=$v"
done < "$OUT/chain.env"

export HORIZON_URL="https://127.0.0.1:${TLS_PORT}"
export OUT_DIR="$OUT"
export NODE_EXTRA_CA_CERTS="$OUT/tls/cert.pem"
export LOCAL_FRIENDBOT_URL="http://127.0.0.1:${NODE_PORT}/friendbot"
export NODE_OPTIONS="--import=${ROOT}/ops/ci/friendbot-redirect.mjs"

echo "== faucet wallet"
node ops/ci/seed-local.mjs

SRC=scripts/e2e-testnet.ts
P=scripts/.e2e-local.ts
sed -E \
  -e 's|^(\s*)const payTaskId = await runPayStage\(.*\);|\1const payTaskId = "";|' \
  -e 's|^(\s*)await runWebhookStage\(.*\);|\1// skipped (needs /payments)|' \
  -e 's|^(\s*)await runIdempotencyStage\(.*\);|\1// skipped (needs /payments)|' \
  -e 's|^(\s*)await runTaskIdempotencyStage\(.*\);|\1// skipped (needs a provider)|' \
  -e 's|^(\s*)await runConcurrentStage\(.*\);|\1// skipped (needs /payments)|' \
  -e 's|^(\s*)const apiKey = await runReachStage\(.*\);|\1const apiKey = "";|' \
  -e 's|^const HORIZON_URL = .*|const HORIZON_URL = process.env.HORIZON_URL as string;|' \
  -e 's|^const USDC_ISSUER = .*|const USDC_ISSUER = process.env.USDC_ISSUER as string;|' \
  -e 's|^const PASSPHRASE = Networks\.TESTNET;|const PASSPHRASE = process.env.NETWORK_PASSPHRASE as string;|' \
  "$SRC" > "$P"
n="$(diff "$SRC" "$P" | grep -c '^>' || true)"
if [ "$n" != 9 ]; then
  rm -f "$P"
  echo "upstream e2e script changed ($n of 9 expected edits matched); update the patch" >&2
  exit 1
fi

mkdir -p "$OUT/logs"
echo "== e2e"
set +e
API_URL="http://127.0.0.1:${API_PORT}" E2E_SKIP_HIRE=1 E2E_SKIP_X402=1 \
  timeout 900 npx tsx "$P" 2>&1 \
  | sed -u -E 's/S[A-Z2-7]{55}/[hidden-secret]/g' | tee "$OUT/logs/e2e.log"
rc=${PIPESTATUS[0]}
set -e
rm -f "$P" wallets.json

# If the summary says every stage passed but the process did not exit, count it as a pass.
if [ "$rc" = 124 ] && grep -Eq '([0-9]+)/\1 stages passed\.' "$OUT/logs/e2e.log"; then
  echo "(all stages passed; the process did not exit and was stopped)"
  rc=0
fi
exit "$rc"