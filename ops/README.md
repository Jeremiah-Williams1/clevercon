# ops/

Infrastructure work for this fork of `clevercon-protocol/clevercon`.

Everything here is independent of upstream application code. Nothing in this folder touches the maintainer's Railway, Cloudflare or live contracts.

## Layout

| Path | Purpose |
|---|---|
| `PLAN.md` | The phased plan (P0 to P6) |
| `FINDINGS.md` | What we found in the system, with recommended fixes |
| `DECISIONS.md` | Decided, open and maintainer-dependent decisions |
| `COSTS.md` | AWS spend log against the $25 cap |
| `scripts/` | Host bootstrap, baseline and report scripts |
| `docs/` | Guides and runbooks |
| `reports/` | Evidence from each run (results, host info, logs) |

## Ground rules

1. Everything new lives in `ops/` (plus new workflow files) to avoid merge conflicts.
2. Changes to upstream files are separate, small, clearly named commits so they can be cherry-picked.
3. One phase at a time. Each phase ends with evidence, not "I configured it".
4. Manual first, then automate.
5. Servers are disposable. Copy reports off, then terminate.
6. Secrets never go into git, chat or logs (`.env`, `wallets.json`, private keys, AWS keys).

## Branches

- `main` mirrors `upstream/main`. Never commit to it.
- Work happens on `infra/main`, rebased onto `upstream/main`, pushed with `git push --force-with-lease`.
- Commits are signed with an SSH signing key.
