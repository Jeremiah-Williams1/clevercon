#!/usr/bin/env bash
# Run ON the staging host (after the staging stack is up): starts node_exporter, cAdvisor and blackbox_exporter,
# and installs the systemd timer that runs metrics.sh every minute.
#   ops/monitoring/staging-collectors/install.sh          # install
#   ops/monitoring/staging-collectors/install.sh --print-ip   # just show the private IP to register in Prometheus
# BIND_IP can be set to override the detected private IP.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(git -C "$HERE" rev-parse --show-toplevel)"
RUN_USER="${SUDO_USER:-$(id -un)}"

detect_ip() {
  local token ip
  token=$(curl -fsS -m 3 -X PUT http://169.254.169.254/latest/api/token \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)
  if [ -n "$token" ]; then
    ip=$(curl -fsS -m 3 -H "X-aws-ec2-metadata-token: $token" \
      http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null || true)
  fi
  if [ -z "${ip:-}" ]; then   # not on EC2 (a VPS): use the source address of the default route
    ip=$(ip -4 route get 1.1.1.1 | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
  fi
  echo "$ip"
}

BIND_IP="${BIND_IP:-$(detect_ip)}"
[[ "$BIND_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "could not find a private IP; set BIND_IP" >&2; exit 1; }
[ "${1:-}" = "--print-ip" ] && { echo "$BIND_IP"; exit 0; }

echo "Binding exporters to $BIND_IP"
echo "BIND_IP=$BIND_IP" >"$HERE/.env"

sudo mkdir -p /var/lib/node_exporter/textfile
sudo chown "$RUN_USER":"$RUN_USER" /var/lib/node_exporter/textfile
sudo chmod 755 /var/lib/node_exporter/textfile

docker compose -f "$HERE/docker-compose.collectors.yml" --env-file "$HERE/.env" up -d

for f in clevercon-metrics.service clevercon-metrics.timer; do
  sed -e "s|@ROOT@|$ROOT|g" -e "s|@USER@|$RUN_USER|g" "$HERE/systemd/$f" | sudo tee "/etc/systemd/system/$f" >/dev/null
done
sudo systemctl daemon-reload
sudo systemctl enable --now clevercon-metrics.timer
sudo systemctl start clevercon-metrics.service || echo "first metrics run failed; see: journalctl -u clevercon-metrics.service" >&2

echo "Done. Register this host in Prometheus with:  ops/monitoring/register-target.sh add $BIND_IP"
