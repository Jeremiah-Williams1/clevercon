#!/usr/bin/env bash
# Start staging: contract check, then data stores, then DB init, then the app.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(git -C "$HERE" rev-parse --show-toplevel)"; cd "$ROOT"
dc() { docker compose --env-file ops/staging/.env.staging -f ops/staging/docker-compose.staging.yml "$@"; }

"$HERE/check-contracts.sh"        # stops here if an ID is wrong
"$HERE/db-init.sh"
dc up -d --wait api workers indexer web
dc ps