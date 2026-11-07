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
run env E2E_SKIP_HIRE=1 E2E_SKIP_X402=1 npx tsx scripts/e2e-testnet.ts