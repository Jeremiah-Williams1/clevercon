#!/usr/bin/env bash
# Run ON the monitoring host. Tells Prometheus which staging host to watch (file_sd), or stops watching it.
#   ops/monitoring/register-target.sh add 10.0.1.23    # start watching
#   ops/monitoring/register-target.sh remove           # stop watching (do this on teardown: no "host down" alert)
#   ops/monitoring/register-target.sh show
# Prometheus re-reads the file within 30 s; no restart needed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FILE="$HERE/prometheus/targets/staging.json"

case "${1:-}" in
  add)
    ip="${2:-}"
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 add <private-ip>" >&2; exit 1; }
    tmp="$(mktemp "$HERE/prometheus/targets/.staging.XXXXXX")"
    cat >"$tmp" <<EOF
[
  {
    "targets": ["$ip"],
    "labels": { "env": "staging", "host": "clevercon-staging" }
  }
]
EOF
    chmod 644 "$tmp"; mv "$tmp" "$FILE"
    echo "watching $ip"
    ;;
  remove)
    rm -f "$FILE"
    echo "no longer watching staging"
    ;;
  show)
    cat "$FILE" 2>/dev/null || echo "(no staging host registered)"
    ;;
  *)
    echo "usage: $0 add <private-ip> | remove | show" >&2; exit 1 ;;
esac
