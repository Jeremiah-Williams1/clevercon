# Staging environment (AWS EC2)

A disposable AWS host that runs the whole backend (API, workers, indexer, Postgres, Redis) plus the web app against Stellar Testnet. GitHub Actions launches it, deploys to it, checks it and tears it down. There are **no inbound ports, no SSH and no AWS keys stored in GitHub**: GitHub proves who it is to AWS with a short-lived token (OIDC), and the host is managed through AWS Systems Manager (SSM).

Cost: a t3.large runs for as long as it exists. Run **teardown** when you are done.

## Branches and promotion

| Branch | Role | GitHub Environment |
|---|---|---|
| `infra/main` | dev | none |
| `infra/staging` | staging (default branch of the fork) | `staging` |
| `infra/prod` | production (not created yet) | `prod` (later) |

Changes only move **up**, by pull request: `infra/main` into `infra/staging` into `infra/prod`. Never the other way. The `promotion-guard` workflow fails any PR that goes the wrong way. Fork `main` is a mirror of upstream and is never committed to.

## What is in `ops/staging/`

| File | What it does |
|---|---|
| `Dockerfile` | Starts from the upstream image (built first as `clevercon-base:local`) and runs as the non-root `node` user. The upstream Dockerfile is untouched. |
| `build.sh` | Builds the upstream image, then ours. |
| `docker-compose.staging.yml` | api, workers, indexer, web, Postgres, Redis. Postgres, Redis, api and web publish on `127.0.0.1` only. Restart policies, log rotation, memory limits. The api has a `/health` check. |
| `.env.staging.example` | The settings template. Holds the (public) contract IDs. |
| `gen-env.sh` | Creates `.env.staging` (mode 600) with fresh random secrets, and fills `INDEXER_CONTRACT_IDS`. Refuses to overwrite. |
| `db-init.sh` | Starts Postgres and Redis, then `db:push` and `db:seed`. When upstream adopts migrations, change only the `SCHEMA_CMD` line. |
| `check-contracts.sh` | For each contract ID: valid checksum, exists on Testnet, vault has the functions we need. |
| `up.sh` | Contract check, then DB init, then starts api, workers, indexer, web. |
| `security-check.sh` | PASS/FAIL lockdown checks (see below). |
| `e2e.sh` | Throwaway-wallet end-to-end test (see below). |

`.env.staging` is never committed (it is excluded locally in `.git/info/exclude`). Before every commit run `git add ops/ .github/ && git status --short` and stop if a secret file shows up.

## One-time setup

### AWS (region `us-east-1`)

1. **OIDC provider** for `token.actions.githubusercontent.com`, client ID `sts.amazonaws.com`.
2. **EC2 role and instance profile**, both named `clevercon-staging-ec2`, with the managed policy `AmazonSSMManagedInstanceCore` (lets the SSM agent register the instance).
3. **Security group** `clevercon-staging` in the default VPC with **no inbound rules**. Outbound stays open: the host needs 443 out for SSM, GitHub, npm and the Stellar RPC.
4. **Deploy role** `clevercon-staging-deploy`, trusting only the `staging` Environment (never `pull_request`). GitHub now puts the numeric owner and repo IDs in the `sub` claim, so the trust policy lists both forms. Find your IDs by printing the token's claims once, or read them from the error in CloudTrail.

   Trust policy (replace the placeholders):
   ```json
   {"Version":"2012-10-17","Statement":[{"Effect":"Allow",
    "Principal":{"Federated":"arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"},
    "Action":"sts:AssumeRoleWithWebIdentity",
    "Condition":{"StringEquals":{
     "token.actions.githubusercontent.com:aud":"sts.amazonaws.com",
     "token.actions.githubusercontent.com:sub":[
      "repo:<OWNER>@<OWNER_ID>/<REPO>@<REPO_ID>:environment:staging",
      "repo:<OWNER>/<REPO>:environment:staging"]}}}]}
   ```
   Permissions (inline policy), all limited to resources tagged `project=clevercon` where AWS allows it:
   - read-only: `ec2:Describe*` (instances, security groups, subnets, images, VPCs), `ssm:DescribeInstanceInformation`, `ssm:GetCommandInvocation`, `ssm:ListCommandInvocations`
   - `ssm:GetParameter` on `/aws/service/canonical/ubuntu/server/24.04/*` (finds the Ubuntu image)
   - `ec2:RunInstances` (instance and volume only with the request tag `project=clevercon`), `ec2:CreateTags` (only while creating), `ec2:StartInstances`, `ec2:StopInstances`, `ec2:TerminateInstances` (tagged instances only)
   - `iam:PassRole` for `clevercon-staging-ec2` only, to `ec2.amazonaws.com`
   - `ssm:SendCommand` on the `AWS-RunShellScript` document and on tagged instances

### GitHub

- **Actions** enabled on the fork (forks start with workflows off).
- **Default branch** `infra/staging`. A `workflow_dispatch` workflow is only listed if its file is on the default branch.
- **Environment `staging`**: required reviewer (you), deployment branches limited to `infra/staging`, variables `AWS_ROLE_ARN` (the deploy role's ARN) and `AWS_REGION`. These are variables, not secrets, because they are not sensitive.
- **Branch protection** on `infra/staging` and `infra/main`: changes through a pull request and required checks (`gitleaks`, `shellcheck`, `image-scan`, `guard` on staging; `guard` on main). Turn off the owner bypass once the checks have been stable for a while.

## Deploy

GitHub, in the fork: **Actions, staging-deploy, Run workflow**. Choose the branch `infra/staging`, action `deploy`, and tick `run_e2e` only if you want the end-to-end test. Approve the review request. The workflow:

1. assumes the deploy role through OIDC,
2. finds the instance tagged `Name=clevercon-staging`, or launches one (Ubuntu 24.04, t3.large, 40 GB encrypted gp3, IMDSv2 required, no key pair) with `ops/scripts/bootstrap-host.sh` as first-boot script,
3. waits until SSM reports the instance online and the bootstrap has finished,
4. runs on the host: check out this commit, `gen-env.sh` (first time only), `build.sh`, `up.sh`,
5. smoke-tests `/health` and `/ready`, then runs `security-check.sh`,
6. optionally runs `e2e.sh`.

A first deploy takes roughly 10 to 15 minutes, mostly the image build.

**Teardown:** run the same workflow with action `teardown`. It terminates the instance and its disk is deleted with it. That also deletes the database, `.env.staging` and the e2e wallets. The next deploy generates fresh secrets.

## Look at it from your laptop

You need the AWS CLI and the `session-manager-plugin`. Find the instance ID (it starts with `i-`; SSM does not accept an IP address):

```bash
aws ec2 describe-instances --region us-east-1 \
  --filters Name=tag:Name,Values=clevercon-staging Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].InstanceId' --output text
```

Open one tunnel per port, each in its own terminal, and leave them open:

```bash
aws ssm start-session --target <instance-id> --region us-east-1 \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["5173"],"localPortNumber":["5173"]}'
aws ssm start-session --target <instance-id> --region us-east-1 \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["4100"],"localPortNumber":["4100"]}'
```

Open `http://localhost:5173`. Both ports are needed: the page comes from 5173 and the browser then calls the API on 4100. `localhost` counts as a secure context, so wallet extensions work without HTTPS. `CORS_ORIGINS` is set to `http://localhost:5173`.

For a shell on the host: `aws ssm start-session --target <instance-id> --region us-east-1`, then `sudo -iu ubuntu` (the repo is in `~/clevercon`, owned by `ubuntu`, not root).

## Checks

**`security-check.sh`** (runs on every deploy; run it by hand any time): nothing listens beyond loopback (port 22 only warns), `.env.staging` is mode 600, api/workers/indexer/web do not run as root, no secrets in the image's metadata or files, `CORS_ORIGINS` and `TRUST_PROXY` are set, `JWT_SECRET` is long enough, IMDSv2 is required.

**`staging-security.yml`** (every PR into or push to `infra/staging` and `infra/prod`):
- `gitleaks` scans the commits in the change for secrets,
- `shellcheck` lints our scripts,
- `image-scan` builds the image and runs Trivy. HIGH and CRITICAL findings are shown; fixable CRITICAL vulnerabilities fail the check. A Testnet contract check also runs there for information only.

**`promotion-guard.yml`**: blocks a PR that would move code down the chain.

## End-to-end test

`ops/staging/e2e.sh` uses a fresh random wallet per run and Testnet. It also needs a funded "faucet" wallet; the script generates its own once (kept in `~/.clevercon-e2e/`, never in the repo) and hides secret keys in its output because Actions logs of a public repo are public.

- `E2E_MODE=core` (default): runs `scripts/e2e-testnet.ts` without the stages that need the retired `POST /payments` route (pay, webhook completion, idempotency, concurrency, SDK/MCP reach). Covers sign-in, deposit, delegate, policy, webhook registration, withdraw and reclaim. A patched copy is mounted over the script inside the container; the file in git is untouched, and the run stops with a message if upstream changes the script.
- `E2E_MODE=full`: the upstream script unchanged. As of writing it fails after 9 stages because the API answers `POST /payments` with 410 Gone.

It writes to the shared Testnet contracts using throwaway wallets, with the maintainer's agreement. Always make sure `API_URL` points at staging: several upstream live scripts default to the production API.

## SDK and MCP

`@clevercon/agent-sdk` and `@clevercon/mcp` are published npm packages that run on the agent builder's machine, not on this host. They matter for staging because their defaults point elsewhere:

| What | Default | Override |
|---|---|---|
| API URL | the production Railway API | MCP: `CLEVERCON_API_URL`. SDK spender: pass your API URL when creating it. |
| Vault and USDC contract | the maintainer's current Testnet contracts (`DEFAULT_TESTNET_VAULT_ID`, `DEFAULT_TESTNET_USDC_SAC` in `packages/agent-sdk/src/sessions.ts`) | MCP: `CLEVERCON_VAULT_ID`, `CLEVERCON_USDC_SAC` |
| Proving files for private payments | a public Cloudflare R2 URL (`DEFAULT_ARTIFACT_BASE_URL`) | local paths or URLs in the artifact options |

Forgetting an override means a test silently talks to production or to the wrong contracts.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | The role's trust policy does not match the token. Print the token's `sub` and compare. GitHub includes numeric IDs (`repo:Owner@id/repo@id:environment:staging`). |
| `Unable to resolve action ... unable to find version` | Action tags now start with `v` (for example `v0.36.0`). |
| `start-session` fails the `target` pattern | `--target` must be the instance ID (`i-...`), not an IP. |
| `sudo -i` lands in an empty root shell | The repo belongs to `ubuntu`. Use `sudo -iu ubuntu`. |
| The workflow is not in the Actions list | The file must be on the default branch, and Actions must be enabled on the fork. |
| A re-run uses old workflow code | "Re-run jobs" replays the old commit. Push a new commit, or close and reopen the PR. |
| Push says `Bypassed rule violations` | Branch protection let you through as owner. Turn on "Do not allow bypassing" when the checks are stable. |
| `check-contracts.sh` reports a row | `BAD-SUM` is a mistyped ID, `NOT-FOUND` means no such contract on Testnet, `NO-FUNC` means the vault lacks a function we need (a stale contract), `RPC-ERROR` is a network or RPC problem. |

## Known gaps

- `check-contracts.sh` is meant to stop `up.sh` on a bad contract ID. During testing it was changed to report without stopping; restore the hard stop. In CI the check is informational only.
- GitHub Actions are pinned to version tags, not commit hashes.
- `SERVER_SIGNING_KEY` is empty, so sign-in challenges in flight do not survive an API restart.
- The bootstrap script has the branch name written in it.
- The e2e does not cover payments, because the only supported spend path needs the zero-knowledge proving files.
- Prisma uses `db push`; there are no migrations upstream yet.
