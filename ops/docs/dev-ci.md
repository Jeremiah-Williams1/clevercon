# Dev checks (GitHub runner, no server)

Everything on a push or pull request to `infra/main` runs inside GitHub's runners. There is no
persistent dev server. `dev-checks.yml` is ours; the maintainer's `ci.yml` runs next to it, and
anything it already covers is not repeated here.

## What runs

| Job | What it checks |
|---|---|
| `gitleaks`, `shellcheck` | secrets in the change, lint of our scripts |
| `packages` | SDK and MCP build, smoke test, package check, web build |
| `services` | service tests with Postgres and Redis |
| `contracts-registry` | rustfmt (informational), clippy and tests for the registry contract |
| `wasm` | builds the three contracts (`wasm32v1-none`, pinned Rust) and records the SHA-256 hashes |
| `local-chain` | deploys this commit's contracts to a local Stellar network, starts the services against it and runs the e2e |

## The local-chain job, step by step

1. `local-node.sh` starts the `stellar/quickstart` image (`--local --limits testnet`). One port serves
   Horizon, RPC and friendbot. Passphrase: `Standalone Network ; February 2017`.
2. `deploy-local.sh` creates a USDC issuer and its asset contract, deploys the verifier and the vault
   from the `wasm` job's files, runs `init` on both and `set_policy_verifier`. It writes the public IDs
   to `.ci-out/chain.env` and throwaway keys to `.ci-out/keys.env`.
3. `tls-proxy.sh` puts a self-signed HTTPS proxy on port 8443. His api, indexer and workers refuse
   `http://` RPC URLs (F29).
4. `start-services.sh` builds and starts api, workers and indexer with the local values. It loads
   `friendbot-redirect.mjs`, which sends his hardcoded friendbot calls to the local friendbot (F28).
5. `e2e-local.sh` creates a faucet wallet funded with our own USDC (`seed-local.mjs`), then runs a
   patched copy of `scripts/e2e-testnet.ts`. His file is not edited, and the run stops if upstream
   changes the 9 lines we patch.

Files: `ops/ci/*`. Nothing here is written into his code.

## What it does not cover

- Payments through `POST /payments` (retired upstream), the webhook, idempotency and concurrency
  stages that depend on it, hire (needs a provider) and x402 (needs the public facilitator).
- The zero-knowledge payment path: needs the proving files and the verifying key installed.
- The web app in a browser (no web smoke test upstream, F26).

## Reading a failure

| Where it fails | Usual cause |
|---|---|
| `local-node.sh` | image tag changed, or a flag was renamed; the container log is printed |
| `deploy-local.sh` | the PR's contract changed an `init` or `set_policy_verifier` signature, or the wasm is over the size limit |
| `start-services.sh` | a service refused its config; the last 40 log lines of each are printed |
| `e2e-local.sh` "N of 9 expected edits" | upstream changed `e2e-testnet.ts`; update the patch |
| `e2e-local.sh` a stage | the log shows the stage; the api log tail is printed on failure |

Logs and the public contract IDs are uploaded as the `local-chain-logs` artifact for 3 days.
Keys are never uploaded.

## Pins and known gaps

- Pinned: Rust (`RUST_VERSION`), `stellar-cli` version and checksum.
- To pin by digest: `stellar/quickstart`, `nginx` (used by the HTTPS proxy).
- The local chain and the e2e are a copy of the maintainer's Testnet flow, not the flow itself.
  Findings F28 (friendbot URL) and F29 (`allowHttp: false`) are worked around, not fixed.
