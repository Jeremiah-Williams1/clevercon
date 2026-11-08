#!/usr/bin/env bash
# Throwaway-wallet e2e against the local staging API. Run on the host, stack up.
# The e2e script makes a fresh random wallet per run. It also needs a "faucet" wallet
# (wallets.json); we generate OUR OWN once and keep it outside the repo.
#
# E2E_MODE=core (default): his script minus the stages that need the retired POST /payments
#   route. Still covers sign-in, deposit, delegate, policy, webhook registration, WITHDRAW
#   and RECLAIM. His file is not edited; a patched copy is mounted over it in the container.
# E2E_MODE=full: his script unchanged (use once he has fixed it).
# E2E_MODE=pp2: his e2e-pp2-live.ts: a real zero-knowledge payment (supported path) with replay
#   check and withdraw. Downloads the proving files once; skips the retired /payments stage.
set -euo pipefail
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"; cd "$ROOT"
dc() { docker compose --env-file ops/staging/.env.staging -f ops/staging/docker-compose.staging.yml "$@"; }

DIR="$HOME/.clevercon-e2e"; W="$DIR/wallets.json"; NEW=0
mkdir -p "$DIR"; chmod 700 "$DIR"
[ -s "$W" ] || { : > "$W"; chmod 600 "$W"; NEW=1; }

EXTRA=()
run() { dc run --rm -T -v "$W:/app/wallets.json" ${EXTRA[@]+"${EXTRA[@]}"} -e API_URL=http://api:4100 api "$@"; }

if [ "$NEW" = 1 ]; then
  echo "creating our own test wallets (output hidden: it prints secret keys)"
  run npx tsx scripts/setup-wallets.ts >/dev/null
  run npx tsx scripts/add-usdc-trustlines.ts
fi

if [ "${E2E_MODE:-core}" = pp2 ]; then
  # A real zero-knowledge payment through the supported path (POST /vault/batch-release-proved):
  # prove, pay, replay (must be blocked), withdraw. Needs the two proving files.
  A="$DIR/artifacts"; mkdir -p "$A"
  BASE="${PP2_ARTIFACT_BASE:-$(sed -nE "s/.*DEFAULT_ARTIFACT_BASE_URL = '([^']+)'.*/\1/p" packages/agent-sdk/src/payments/artifacts-base.ts)}"
  [ -n "$BASE" ] || { echo "could not find the artifact URL; set PP2_ARTIFACT_BASE" >&2; exit 1; }
  for f in policy_batch.wasm policy_batch_final.zkey; do
    if [ ! -s "$A/$f" ]; then
      echo "downloading $f ..."
      curl -fSL --retry 3 -w '  %{size_download} bytes in %{time_total}s\n' -o "$A/$f.part" "$BASE/$f" \
        && mv "$A/$f.part" "$A/$f" || { echo "download failed: $BASE/$f" >&2; exit 1; }
    fi
  done
  ls -lh "$A"
  set +e
  docker rm -f clevercon-e2e-pp2 >/dev/null 2>&1
  # timeout: proving normally takes about a minute; give up after 20 minutes instead of hanging
  # His script prints "N/N stages passed" but then never exits (the proving workers keep node alive),
  # so we watch the output: once the summary line appears, stop the container and judge by that line.
  LOG="$(mktemp)"
  timeout 1200 docker run --rm --name clevercon-e2e-pp2 --network clevercon-staging_default --memory 3g \
    -v "$W:/app/wallets.json" -v "$A:/artifacts:ro" \
    -e API_URL=http://api:4100 \
    -e PP2_WASM=/artifacts/policy_batch.wasm -e PP2_ZKEY=/artifacts/policy_batch_final.zkey \
    -e E2E_SKIP_PP1=1 -e NODE_OPTIONS=--max-old-space-size=2560 \
    clevercon-staging:local npx tsx scripts/e2e-pp2-live.ts 2>&1 \
    | sed -u -E 's/S[A-Z2-7]{55}/[hidden-secret]/g' | tee "$LOG" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if grep -Eq '[0-9]+/[0-9]+ stages passed' "$LOG"; then
      sleep 15
      echo "(summary printed; stopping the test container, which would otherwise not exit)"
      docker stop -t 5 clevercon-e2e-pp2 >/dev/null 2>&1
      break
    fi
    sleep 5
  done
  wait "$pid"
  docker rm -f clevercon-e2e-pp2 >/dev/null 2>&1
  summary="$(grep -Eo '[0-9]+/[0-9]+ stages passed' "$LOG" | tail -n 1)"
  rm -f "$LOG"
  if [ -z "$summary" ]; then
    echo "pp2 e2e did not finish (no summary line; timed out after 20 minutes or crashed)" >&2
    exit 1
  fi
  done_n="${summary%%/*}"; rest="${summary#*/}"; total_n="${rest%% *}"
  [ "$done_n" = "$total_n" ] || { echo "pp2 e2e FAILED: $summary" >&2; exit 1; }
  echo "pp2 e2e OK: $summary"
  exit 0
fi

SRC=scripts/e2e-testnet.ts
if [ "${E2E_MODE:-core}" = core ]; then
  P="$(mktemp --suffix=.ts)"; chmod 644 "$P"
  sed -E \
    -e 's|^(\s*)const payTaskId = await runPayStage\(.*\);|\1const payTaskId = "";|' \
    -e 's|^(\s*)await runWebhookStage\(.*\);|\1// skipped (needs /payments)|' \
    -e 's|^(\s*)await runIdempotencyStage\(.*\);|\1// skipped (needs /payments)|' \
    -e 's|^(\s*)await runTaskIdempotencyStage\(.*\);|\1// skipped (needs a provider)|' \
    -e 's|^(\s*)await runConcurrentStage\(.*\);|\1// skipped (needs /payments)|' \
    -e 's|^(\s*)const apiKey = await runReachStage\(.*\);|\1const apiKey = "";|' \
    "$SRC" > "$P"
  n=$(diff "$SRC" "$P" | grep -c '^>' || true)
  if [ "$n" != 6 ]; then
    echo "upstream e2e script changed ($n of 6 expected edits matched). Try: E2E_MODE=full" >&2; exit 1
  fi
  EXTRA=(-v "$P:/app/$SRC:ro")
fi

OUT="$(mktemp)"
set +e
# sed hides any Stellar secret key (the script prints its throwaway buyer key; Actions logs are public)
run env E2E_SKIP_HIRE=1 E2E_SKIP_X402=1 npx tsx "$SRC" 2>&1 \
  | sed -E 's/S[A-Z2-7]{55}/[hidden-secret]/g' | tee "$OUT"
rc=${PIPESTATUS[0]}
set -e
[ "$rc" = 0 ] && exit 0

# Full mode only: his script still calls the retired POST /payments (HTTP 410).
if grep -q 'FAILED: /payments 410' "$OUT" && grep -Eq '([0-9]+)/\1 stages passed before failure' "$OUT"; then
  echo "KNOWN ISSUE: e2e-testnet.ts calls the retired /payments route; earlier stages all passed."
  exit 0
fi
exit "$rc"