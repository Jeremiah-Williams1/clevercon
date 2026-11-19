#!/usr/bin/env bash
# Build the upstream image, then our non-root layer on top. Run from anywhere.
set -euo pipefail
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$ROOT"
docker build -t clevercon-base:local -f Dockerfile .
docker compose --env-file ops/staging/.env.staging \
  -f ops/staging/docker-compose.staging.yml build