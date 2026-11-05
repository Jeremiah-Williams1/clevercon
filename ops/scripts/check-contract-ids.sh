#!/usr/bin/env bash
# Validates the Stellar contract IDs in .env. Run on the host after `baseline.sh checks`.
#
# A Stellar contract ID ends with a built-in checksum, so one mistyped character makes it
# invalid. This catches that before the API is restarted. Contract IDs are public, so the
# values are printed in full. Nothing secret is read or printed.
#
# Usage:  ./ops/scripts/check-contract-ids.sh
# Exit code: 0 when every required ID is valid, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" \
  || { echo "x this script must live inside the git checkout"; exit 1; }
cd "$REPO" || exit 1

[ -f .env ] || { echo "x no .env in $REPO; run ./ops/scripts/baseline.sh checks first"; exit 1; }
[ -d node_modules/@stellar/stellar-sdk ] || { echo "x dependencies are not installed; run ./ops/scripts/baseline.sh checks first"; exit 1; }

node - <<'JS'
const { StrKey } = require('@stellar/stellar-sdk');
const fs = require('fs');

const env = {};
for (const line of fs.readFileSync('.env', 'utf8').split('\n')) {
  const m = line.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
  if (m) env[m[1]] = m[2].trim();
}

let bad = 0;
const row = (k, status, id = '') => console.log(`${k.padEnd(28)} ${status.padEnd(8)} ${id}`);

function check(key, required) {
  const raw = env[key];
  if (!raw) {
    if (required) { row(key, 'MISSING'); bad++; } else { row(key, '(unset)'); }
    return [];
  }
  const ids = raw.split(',').map((s) => s.trim()).filter(Boolean);
  for (const id of ids) {
    const ok = StrKey.isValidContract(id);
    if (!ok) bad++;
    row(key, ok ? 'OK' : 'INVALID', id);
  }
  return ids;
}

const vault = check('AGENT_VAULT_CONTRACT_ID', true);
const verifier = check('POLICY_VERIFIER_CONTRACT_ID', true);
check('USDC_SAC', true);
check('REGISTRY_CONTRACT_ID', false);
const indexed = check('INDEXER_CONTRACT_IDS', true);

for (const id of [...vault, ...verifier]) {
  if (indexed.length && !indexed.includes(id)) {
    console.log(`WARN: ${id.slice(0, 8)}... is not in INDEXER_CONTRACT_IDS, so the indexer will not watch it`);
  }
}

console.log(bad === 0 ? '\nAll required contract IDs are valid.' : `\n${bad} problem(s). Fix .env, then restart api, workers and indexer.`);
process.exit(bad === 0 ? 0 : 1);
JS
