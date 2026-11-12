#!/usr/bin/env bash
# Run ON the monitoring host, from the repo checkout (the workflow calls it over SSM; on a VPS, call it over ssh).
# If SLACK_B64 / GRAFANA_B64 (base64 values) are set, writes the secret files from them. If not, the existing
# files are kept. Then recreates the stack, makes the Grafana admin password match the file, and checks health.
set -euo pipefail
cd "$(dirname "$0")"
dc() { docker compose -f docker-compose.monitoring.yml "$@"; }

install -d -m 700 secrets
write_secret() { # <name of the variable holding the base64 value> <file name>
  local var=$1 file=$2 tmp
  if [ -n "${!var:-}" ]; then
    tmp="$(mktemp secrets/.tmp.XXXXXX)"
    printf '%s' "${!var}" | base64 -d >"$tmp"
    chmod 644 "$tmp"   # the containers run as other users and must read these
    mv "$tmp" "secrets/$file"
    echo "wrote secrets/$file"
  fi
  [ -s "secrets/$file" ] || { echo "secrets/$file is missing or empty" >&2; exit 1; }
}
write_secret SLACK_B64 slack_url
write_secret GRAFANA_B64 grafana_admin_password

case "$(cat secrets/slack_url)" in
  https://hooks.slack.com/services/*) ;;
  *) echo "secrets/slack_url is not a Slack webhook URL" >&2; exit 1 ;;
esac
[ "$(wc -c <secrets/grafana_admin_password)" -ge 8 ] || { echo "grafana admin password is shorter than 8 characters" >&2; exit 1; }

dc up -d --force-recreate

# Grafana only reads the password file when it first creates its database, so sync it explicitly.
ok=0
for _ in 1 2 3 4 5 6; do
  if dc exec -T grafana sh -c 'grafana cli admin reset-admin-password "$(cat /run/secrets/grafana_admin_password)"' >/dev/null 2>&1; then ok=1; break; fi
  sleep 10
done
if [ "$ok" = 1 ]; then echo "grafana admin password synced"; else echo "WARNING: could not sync the grafana admin password" >&2; fi

dc ps
dc exec -T alertmanager amtool check-config /etc/alertmanager/alertmanager.yml
for _ in $(seq 1 12); do curl -fsS localhost:9090/-/ready >/dev/null 2>&1 && break; sleep 5; done
curl -fsS localhost:9090/-/ready