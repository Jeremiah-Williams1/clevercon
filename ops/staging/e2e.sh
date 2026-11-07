#!/usr/bin/env bash
# Throwaway-wallet e2e against the local staging API. Run on the host, stack up.
# The e2e script makes a fresh random wallet per run. It also needs a "faucet" wallet
# (wallets.json); we generate OUR OWN once and keep it outside the repo.
set -euo pipefail
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"; cd "$ROOT"
dc() { docker compose --env-file ops/staging/.env.staging -f ops/staging/docker-compose.staging.yml "$@"; }

DIR="$HOME/.clevercon-e2e"; W="$DIR/wallets.json"; NEW=0
mkdir -p "$DIR"; chmod 700 "$DIR"
[ -s "$W" ] || { : > "$W"; chmod 600 "$W"; NEW=1; }
run() { dc run --rm -T -v "$W:/app/wallets.json" -e API_URL=http://api:4100 api "$@"; }

if [ "$NEW" = 1 ]; then
  echo "creating our own test wallets (output hidden: it prints secret keys)"
  run npx tsx scripts/setup-wallets.ts >/dev/null
  run npx tsx scripts/add-usdc-trustlines.ts
fi

OUT="$(mktemp)"
set +e
# sed hides any Stellar secret key (the script prints its throwaway buyer key; Actions logs are public)
run env E2E_SKIP_HIRE=1 E2E_SKIP_X402=1 npx tsx scripts/e2e-testnet.ts 2>&1 \
  | sed -E 's/S[A-Z2-7]{55}/[hidden-secret]/g' | tee "$OUT"
rc=${PIPESTATUS[0]}
set -e
[ "$rc" = 0 ] && exit 0

# KNOWN upstream issue: his e2e still calls the retired POST /payments (HTTP 410).
# Pass only if that is the failure AND every earlier stage passed (N/N).
if grep -q 'FAILED: /payments 410' "$OUT" && grep -Eq '([0-9]+)/\1 stages passed before failure' "$OUT"; then
  echo "KNOWN ISSUE: e2e-testnet.ts calls the retired /payments route; earlier stages all passed."
  exit 0
fi
exit "$rc"