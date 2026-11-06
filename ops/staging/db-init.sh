#!/usr/bin/env bash
# Create/update the database schema and load seed data. Safe to re-run.
set -euo pipefail
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"; cd "$ROOT"
dc() { docker compose --env-file ops/staging/.env.staging -f ops/staging/docker-compose.staging.yml "$@"; }

# Schema step. `db:push` has no --accept-data-loss, so it stops instead of deleting data.
# When the maintainer adopts migrations, change ONLY this line to:
#   npx prisma migrate deploy --schema packages/db/prisma/schema.prisma
SCHEMA_CMD="npm run db:push"
SEED_CMD="npm run db:seed"

dc up -d --wait postgres redis
dc run --rm --no-deps -T api sh -c "$SCHEMA_CMD"
dc run --rm --no-deps -T api sh -c "$SEED_CMD"
echo "db-init done"