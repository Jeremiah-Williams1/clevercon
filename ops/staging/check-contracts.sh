#!/usr/bin/env bash
# Checks the contract IDs in .env.staging, verifies they exist on Testnet, and checks
# the vault functions. A policy-verifier checksum mismatch is warning-only in staging.
# Contract IDs are public; no secrets are printed. Runs inside the staging image.
set -euo pipefail
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"; cd "$ROOT"
dc() { docker compose --env-file ops/staging/.env.staging -f ops/staging/docker-compose.staging.yml "$@"; }

dc run --rm --no-deps -T api node - <<'JS'
const { StrKey, Contract, rpc } = require('@stellar/stellar-sdk');
const e = process.env;
const server = new rpc.Server(e.STELLAR_RPC_URL);
const VAULT_FNS = ['set_public_rule', 'register_session']; // add more as we rely on them
let bad = 0;
const row = (k, s, x = '') => console.log(`${k.padEnd(28)} ${s.padEnd(10)} ${x}`);

async function check(key, fns, checksumWarningOnly = false) {
  const id = e[key];
  if (!id) { row(key, 'MISSING'); bad++; return; }
  if (!StrKey.isValidContract(id)) {
    row(key, checksumWarningOnly ? 'BAD-SUM-WARN' : 'BAD-SUM', id);
    if (!checksumWarningOnly) bad++;
    return;
  }
  try {
    const r = await server.getLedgerEntries(new Contract(id).getFootprint());
    if (!r.entries.length) { row(key, 'NOT-FOUND', id); bad++; return; }
  } catch (err) { row(key, 'RPC-ERROR', err.message); bad++; return; }
  if (!fns) { row(key, 'OK', id); return; }
  try {
    // Function names appear as plain text in the contract's Wasm spec.
    const wasm = await server.getContractWasmByContractId(id);
    const missing = fns.filter((f) => !wasm.includes(Buffer.from(f)));
    if (missing.length) { row(key, 'NO-FUNC', missing.join(',')); bad++; return; }
    row(key, 'OK', id);
  } catch (err) { row(key, 'WASM-ERROR', err.message); bad++; }
}

(async () => {
  await check('AGENT_VAULT_CONTRACT_ID', VAULT_FNS);
  await check('POLICY_VERIFIER_CONTRACT_ID', [], true);
  await check('USDC_SAC'); // a built-in token contract: existence only
  const indexed = (e.INDEXER_CONTRACT_IDS || '').split(',');
  for (const k of ['AGENT_VAULT_CONTRACT_ID', 'POLICY_VERIFIER_CONTRACT_ID']) {
    if (!indexed.includes(e[k])) { row('INDEXER_CONTRACT_IDS', 'MISSING', k); bad++; }
  }
  console.log(bad ? `\n${bad} problem(s): refusing to continue.` : '\nAll contract checks passed.');
  process.exit(bad ? 1 : 0);
})();
JS