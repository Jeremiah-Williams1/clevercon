#!/usr/bin/env bash
# Deploy THIS commit's contracts to the local network and write their IDs to .ci-out/chain.env.
# Needs: local-node.sh already running, the stellar CLI, `npm ci` done (for the key generator),
# and the wasm files from the dev-checks "wasm" job.
# Order (from the contract source, not the old runbook):
#   USDC asset contract, verifier deploy+init, vault deploy+init(admin, usdc_sac), set_policy_verifier.
# The verifying key is not installed: the core e2e does not make zero-knowledge payments.
set -euo pipefail
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

PORT="${NODE_PORT:-8000}"
RPC_URL="http://127.0.0.1:${PORT}/rpc"
HORIZON_URL="http://127.0.0.1:${PORT}"
FRIENDBOT_URL="http://127.0.0.1:${PORT}/friendbot"
PASSPHRASE="Standalone Network ; February 2017"
WASM_DIR="${WASM_DIR:-artifacts}"
OUT_DIR="${OUT_DIR:-.ci-out}"
NET=(--rpc-url "$RPC_URL" --network-passphrase "$PASSPHRASE")

log() { echo "[deploy-local] $*"; }

wasm_file() {
  local f
  f="$(find "$WASM_DIR" -name "$1" -type f | head -n 1)"
  [ -n "$f" ] || { echo "missing $1 under $WASM_DIR" >&2; exit 1; }
  echo "$f"
}

newkey() {
  node -e "const {Keypair}=require('@stellar/stellar-sdk');const k=Keypair.random();console.log(k.publicKey()+' '+k.secret())"
}

fund() {
  local i
  for i in 1 2 3 4 5 6; do
    if curl -fsS -m 30 "${FRIENDBOT_URL}?addr=$1" >/dev/null; then return 0; fi
    sleep 5
  done
  echo "friendbot did not fund $1" >&2
  return 1
}

need_id() { # name value
  case "$2" in
    C??????????????????????????????????????????????????????) ;;
    *) echo "$1 is not a contract ID: '$2'" >&2; exit 1 ;;
  esac
}

read -r ADMIN_PUB ADMIN_SEC < <(newkey)
read -r ISSUER_PUB ISSUER_SEC < <(newkey)
[ -n "${ADMIN_SEC:-}" ] && [ -n "${ISSUER_SEC:-}" ] || { echo "key generation failed" >&2; exit 1; }
# Throwaway local keys, but keep them out of the Actions log anyway.
echo "::add-mask::$ADMIN_SEC"
echo "::add-mask::$ISSUER_SEC"

log "funding the admin and USDC issuer accounts"
fund "$ADMIN_PUB"
fund "$ISSUER_PUB"

log "creating the USDC asset contract (issuer ${ISSUER_PUB})"
USDC_SAC="$(stellar contract asset deploy --asset "USDC:${ISSUER_PUB}" --source-account "$ADMIN_SEC" "${NET[@]}")"
need_id USDC_SAC "$USDC_SAC"

log "deploying the policy verifier"
VERIFIER_ID="$(stellar contract deploy --wasm "$(wasm_file policy_verifier.wasm)" --source-account "$ADMIN_SEC" "${NET[@]}")"
need_id VERIFIER_ID "$VERIFIER_ID"

log "deploying the vault"
VAULT_ID="$(stellar contract deploy --wasm "$(wasm_file agent_vault.wasm)" --source-account "$ADMIN_SEC" "${NET[@]}")"
need_id VAULT_ID "$VAULT_ID"

log "init verifier"
stellar contract invoke --id "$VERIFIER_ID" --source-account "$ADMIN_SEC" "${NET[@]}" \
  -- init --admin "$ADMIN_PUB"

log "init vault"
stellar contract invoke --id "$VAULT_ID" --source-account "$ADMIN_SEC" "${NET[@]}" \
  -- init --admin "$ADMIN_PUB" --usdc_sac "$USDC_SAC"

log "wire the vault to the verifier"
stellar contract invoke --id "$VAULT_ID" --source-account "$ADMIN_SEC" "${NET[@]}" \
  -- set_policy_verifier --admin "$ADMIN_PUB" --verifier "$VERIFIER_ID"

log "smoke test: task_count (expect 0)"
stellar contract invoke --id "$VAULT_ID" --source-account "$ADMIN_SEC" "${NET[@]}" -- task_count

mkdir -p "$OUT_DIR"
# Public values only. Quoted so a dotenv loader keeps the spaces and the semicolon.
{
  echo "NETWORK_PASSPHRASE=\"$PASSPHRASE\""
  echo "STELLAR_RPC_URL=$RPC_URL"
  echo "HORIZON_URL=$HORIZON_URL"
  echo "FRIENDBOT_URL=$FRIENDBOT_URL"
  echo "AGENT_VAULT_CONTRACT_ID=$VAULT_ID"
  echo "POLICY_VERIFIER_CONTRACT_ID=$VERIFIER_ID"
  echo "INDEXER_CONTRACT_IDS=$VAULT_ID"
  echo "USDC_SAC=$USDC_SAC"
  echo "USDC_ISSUER=$ISSUER_PUB"
} > "$OUT_DIR/chain.env"

# Secrets (throwaway): readable by this user only. Never source this file; read it with a dotenv loader.
(
  umask 077
  {
    echo "ADMIN_PUBLIC=$ADMIN_PUB"
    echo "ADMIN_SECRET=$ADMIN_SEC"
    echo "ISSUER_PUBLIC=$ISSUER_PUB"
    echo "ISSUER_SECRET=$ISSUER_SEC"
  } > "$OUT_DIR/keys.env"
)

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Local chain: contracts deployed"
    echo '~~~'
    cat "$OUT_DIR/chain.env"
    echo '~~~'
  } >> "$GITHUB_STEP_SUMMARY"
fi
log "done: $OUT_DIR/chain.env written"