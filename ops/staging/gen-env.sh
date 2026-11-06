#!/usr/bin/env bash
# Create .env.staging (mode 600) with fresh secrets. Refuses to overwrite.
set -euo pipefail
cd "$(dirname "$0")"
[ -e .env.staging ] && { echo "refusing: .env.staging already exists" >&2; exit 1; }
umask 077
gen() { openssl rand -hex "$1"; }
sed -e "s/__PG__/$(gen 24)/g" -e "s/__REDIS__/$(gen 24)/g" \
    -e "s/__JWT__/$(gen 32)/g" -e "s/__DELEGATE__/$(gen 32)/g" \
    .env.staging.example > .env.staging
chmod 600 .env.staging

val() { grep "^$1=" .env.staging | cut -d= -f2-; }
vault=$(val AGENT_VAULT_CONTRACT_ID); ver=$(val POLICY_VERIFIER_CONTRACT_ID)
case "$ver" in C????????????????????????????????????????????????????????) ;; *)
  rm -f .env.staging; echo "set POLICY_VERIFIER_CONTRACT_ID in the .example first" >&2; exit 1;; esac
sed -i "s|^INDEXER_CONTRACT_IDS=.*|INDEXER_CONTRACT_IDS=$vault,$ver|" .env.staging
echo "created .env.staging (600). Next: run check-contract-ids.sh against it."