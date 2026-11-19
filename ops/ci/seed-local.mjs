// CI only. Creates the e2e "faucet" wallet (wallets.json in the repo root, which is gitignored)
// and funds it with local USDC minted by OUR issuer. This replaces setup-wallets.ts,
// add-usdc-trustlines.ts and the DEX swap, which only work on Testnet.
import fs from 'node:fs';
import { Asset, BASE_FEE, Horizon, Keypair, Operation, TransactionBuilder } from '@stellar/stellar-sdk';

const need = (k) => {
  const v = process.env[k];
  if (!v) throw new Error(`${k} is not set`);
  return v;
};

function readEnvFile(p) {
  const o = {};
  for (const line of fs.readFileSync(p, 'utf-8').split('\n')) {
    const i = line.indexOf('=');
    if (i > 0) o[line.slice(0, i)] = line.slice(i + 1).replace(/^"|"$/g, '');
  }
  return o;
}

const keys = readEnvFile(`${need('OUT_DIR')}/keys.env`);
const horizon = new Horizon.Server(need('HORIZON_URL'));
const passphrase = need('NETWORK_PASSPHRASE');
const issuer = Keypair.fromSecret(keys.ISSUER_SECRET);
if (issuer.publicKey() !== need('USDC_ISSUER')) throw new Error('issuer key does not match USDC_ISSUER');
const usdc = new Asset('USDC', issuer.publicKey());
const faucet = Keypair.random();

const fb = await fetch(`${need('LOCAL_FRIENDBOT_URL')}?addr=${faucet.publicKey()}`);
if (!fb.ok) throw new Error(`friendbot failed: ${fb.status}`);

async function submit(kp, op) {
  const acct = await horizon.loadAccount(kp.publicKey());
  const tx = new TransactionBuilder(acct, { fee: BASE_FEE, networkPassphrase: passphrase })
    .addOperation(op)
    .setTimeout(60)
    .build();
  tx.sign(kp);
  return (await horizon.submitTransaction(tx)).hash;
}

await submit(faucet, Operation.changeTrust({ asset: usdc }));
await submit(issuer, Operation.payment({ destination: faucet.publicKey(), asset: usdc, amount: '100000' }));

fs.writeFileSync(
  'wallets.json',
  JSON.stringify({ orchestrator: { publicKey: faucet.publicKey(), secretKey: faucet.secret() } }, null, 2),
  { mode: 0o600 },
);
console.log(`faucet wallet ${faucet.publicKey()} funded with 100000 local USDC (wallets.json written)`);