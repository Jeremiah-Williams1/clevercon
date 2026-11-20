#!/usr/bin/env bash
# Start a throwaway local npm registry (Verdaccio) for the release rehearsal.
# Nothing real is touched: @clevercon/* lives only in this registry (never fetched from npmjs, so a
# rehearsal install can never silently use the real published packages); every other package is
# proxied read-only from npmjs. Anyone can publish here with any token. It is for rehearsals only.
set -euo pipefail
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

PORT="${REGISTRY_PORT:-4873}"
VERDACCIO_VERSION="${VERDACCIO_VERSION:-6.1.2}"
OUT="$(pwd)/${OUT_DIR:-.ci-out}/verdaccio"

rm -rf "$OUT"
mkdir -p "$OUT/storage"

cat > "$OUT/config.yaml" <<EOF
storage: $OUT/storage
auth:
  htpasswd:
    file: $OUT/htpasswd
    max_users: -1
uplinks:
  npmjs:
    url: https://registry.npmjs.org/
packages:
  '@clevercon/*':
    access: \$all
    publish: \$anonymous
  '**':
    access: \$all
    proxy: npmjs
log: { type: stdout, format: pretty, level: warn }
EOF

setsid nohup npx --yes "verdaccio@${VERDACCIO_VERSION}" \
  --config "$OUT/config.yaml" --listen "127.0.0.1:${PORT}" > "$OUT/verdaccio.log" 2>&1 &
echo "$!" > "$OUT/pid"

for _ in $(seq 1 90); do
  if curl -fsS "http://127.0.0.1:${PORT}/-/ping" > /dev/null 2>&1; then
    echo "registry ready on http://127.0.0.1:${PORT}/"
    exit 0
  fi
  sleep 1
done
echo "the local registry did not start; last log lines:" >&2
tail -n 30 "$OUT/verdaccio.log" >&2
exit 1
