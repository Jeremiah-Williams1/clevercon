#!/usr/bin/env bash
# Run ON the monitoring host. Writes ops/monitoring/secrets/* from SSM Parameter Store (SecureString),
# using the instance role. Prints no secret values. Safe to re-run: it overwrites with the current values.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REGION="${AWS_REGION:-us-east-1}"
PREFIX="${PARAM_PREFIX:-/clevercon/monitoring}"

# Ubuntu 24.04 has no awscli package; the snap is the supported install.
command -v aws >/dev/null 2>&1 || [ -x /snap/bin/aws ] || sudo snap install aws-cli --classic >/dev/null
AWS="$(command -v aws || echo /snap/bin/aws)"

install -d -m 700 "$HERE/secrets"
fetch() { # <parameter name> <file name>
  local tmp
  tmp="$(mktemp "$HERE/secrets/.tmp.XXXXXX")"
  "$AWS" ssm get-parameter --region "$REGION" --with-decryption --name "$PREFIX/$1" \
    --query Parameter.Value --output text | tr -d '\n' >"$tmp"
  [ -s "$tmp" ] || { rm -f "$tmp"; echo "parameter $PREFIX/$1 is empty or missing" >&2; exit 1; }
  chmod 644 "$tmp"   # the containers run as other users and must read these
  mv "$tmp" "$HERE/secrets/$2"
  echo "wrote secrets/$2"
}
fetch slack_webhook slack_url
fetch grafana_admin_password grafana_admin_password