# Dev environment on EC2

A disposable AWS host that runs the whole CleverCon stack (Postgres, Redis, API, workers, indexer and the web app) against Stellar Testnet. You reach it from your laptop over an SSH tunnel. Nothing is exposed to the internet except SSH from your own IP.

Time: about 30 minutes the first time. Cost: roughly $0.10 per hour on a t3.large.

## You need

- An AWS account and an EC2 key pair (`.pem` file).
- A laptop with `ssh`, and a browser with a Stellar wallet extension (Freighter or xBull) switched to **Testnet**.
- The current Testnet contract IDs from the maintainer: the vault and the policy verifier. They are public, not secrets.
- This fork pushed to GitHub with `ops/` on the branch the host clones (`infra/main`). To use another fork or branch, edit `REPO_URL` and `BRANCH` at the top of `ops/scripts/bootstrap-host.sh`.

## 1. Launch the instance (AWS console)

| Setting | Value |
|---|---|
| Image | Ubuntu Server 24.04 LTS |
| Instance type | t3.large (2 vCPU, 8 GB RAM) |
| Disk | 40 GB gp3 |
| Security group | Inbound: SSH (22) from **My IP** only. Nothing else. |
| Metadata version | V2 only (under Advanced details) |
| Tag | `project=clevercon` |
| User data | Paste the full text of `ops/scripts/bootstrap-host.sh` |

Never open ports 4100, 5173, 5432 or 6379. Everything goes through the SSH tunnel.

## 2. Wait for the bootstrap

On your **laptop**:

```bash
ssh -i /path/to/key.pem ubuntu@<public-ip>
```

On the **instance**:

```bash
sudo tail -f /var/log/bootstrap.log     # wait for "BOOTSTRAP DONE" (about 5 minutes), then Ctrl-c
cat /var/lib/clevercon/bootstrap.done   # installed versions and the commit that was cloned
```

Log out and SSH back in, so your user picks up the `docker` group.

## 3. Make tmux easier to use (optional, recommended)

```bash
printf 'set -g mouse on\nset -g history-limit 50000\n' > ~/.tmux.conf
```

Scroll with the mouse wheel, or press `Ctrl-b [` and use PageUp. Press `q` to leave scroll mode.

## 4. Run the checks and create the base configuration

```bash
tmux new -s dev
cd ~/clevercon
./ops/scripts/baseline.sh checks
```

This creates `.env` with freshly generated secrets, starts Postgres and Redis bound to loopback only, installs dependencies, prepares and seeds the database, and runs the quality gates. It prints PASS or FAIL per step and saves logs under `~/clevercon-reports/<timestamp>/`. A failing quality gate comes from the upstream code and does not stop the dev environment from running. It takes about 5 minutes.

## 5. Set the contract IDs

The example IDs in `.env.example` may not match the contracts the maintainer currently runs. Ask him for the current vault and policy-verifier IDs, then set them. Leave `USDC_SAC` at its default unless he says otherwise.

```bash
cd ~/clevercon
V=<vault id>
P=<policy verifier id>
sed -i "s|^AGENT_VAULT_CONTRACT_ID=.*|AGENT_VAULT_CONTRACT_ID=$V|" .env
sed -i "s|^POLICY_VERIFIER_CONTRACT_ID=.*|POLICY_VERIFIER_CONTRACT_ID=$P|" .env
grep -q '^INDEXER_CONTRACT_IDS=' .env \
  && sed -i "s|^INDEXER_CONTRACT_IDS=.*|INDEXER_CONTRACT_IDS=$V|" .env \
  || echo "INDEXER_CONTRACT_IDS=$V,$P" >> .env
./ops/scripts/check-contract-ids.sh
```

Put only the vault ID in this list: the indexer watches the vault (confirmed by the maintainer). The verifier ID is still needed by the API, but not by the indexer.

## 6. Prepare the web app configuration

```bash
./ops/scripts/baseline.sh dev
```

This writes `apps/web/.env.local` (git-ignored), makes sure Postgres and Redis are up, and prints the commands below. Vite reads its environment files from `apps/web/`, not from the repository root.

## 7. Start the four services

Use one tmux window each (`Ctrl-b c` creates a window, `Ctrl-b n` moves to the next). To keep a log file per service, pipe through `tee`:

```bash
mkdir -p ~/clevercon-logs
cd ~/clevercon
npm run dev -w @clevercon/api       2>&1 | tee -a ~/clevercon-logs/api.log       # API on :4100
npm run dev -w @clevercon/workers   2>&1 | tee -a ~/clevercon-logs/workers.log
npm run dev -w @clevercon/indexer   2>&1 | tee -a ~/clevercon-logs/indexer.log
npm run dev -w @clevercon/web       2>&1 | tee -a ~/clevercon-logs/web.log       # web app (Vite) on :5173
```

The services read `.env` only at startup. After changing it, stop each service with `Ctrl-c` and start it again.

## 8. Verify on the instance

```bash
curl -s localhost:4100/ready     # expect {"status":"ready","checks":{"db":"up","redis":"up","rpc":"up"},...}
ss -tln | grep -E ':(4100|5173)' # 4100 and 5173 should both be listening
```

## 9. Open the tunnel and use the app

On your **laptop**, in a new terminal (leave it open; it looks frozen, which is normal):

```bash
ssh -N -i /path/to/key.pem -L 5173:localhost:5173 -L 4100:localhost:4100 ubuntu@<public-ip>
```

Browse to `http://localhost:5173`. Both ports are needed: the page comes from 5173, and the page then calls the API at `localhost:4100` from your browser.

Wallet: set it to **Testnet**. The app's Vault tab has a one-click testnet quickstart (XLM, USDC trustline and test funds). As a fallback, Stellar's public Friendbot funds any testnet address with XLM:

```bash
curl "https://friendbot.stellar.org/?addr=<your G... address>"
```

Sign in with the wallet, then try the flows (deposit, set a rule on-chain, register an agent key). Each should open the wallet to sign.

## 10. Finish

On your **laptop**, copy the reports and logs off the instance. Never copy `.env`, which holds secrets:

```bash
scp -i /path/to/key.pem -r ubuntu@<public-ip>:clevercon-reports ./clevercon-reports
scp -i /path/to/key.pem -r ubuntu@<public-ip>:clevercon-logs ./clevercon-logs
```

Then, in the AWS console:
- **Terminate** the instance to delete everything and stop all charges.
- **Stop** it instead if you will continue soon. The disk (about $0.10 per day) and `.env` are kept, but the public IP changes on restart and the tmux sessions end. After restarting, SSH to the new IP, run `./ops/scripts/baseline.sh dev`, and start the four services again.

## Notes

- This environment uses the shared Testnet contracts. Do not run the end-to-end script (`scripts/e2e-testnet.ts`) or other flows that write many transactions here.
- Keep `DELEGATE_ENCRYPTION_KEY` from `.env` safe if you keep the host: if it is lost, stored delegate keys can no longer be decrypted.
- Secrets live only in `.env` on the host. Never commit them or paste them into chat.
