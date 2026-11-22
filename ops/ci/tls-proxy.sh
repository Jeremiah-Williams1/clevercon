#!/usr/bin/env bash
# HTTPS front for the local Stellar network. His api, indexer and workers create their Soroban
# RPC client with allowHttp:false, so they refuse http:// URLs (F29). This puts a throwaway
# self-signed TLS proxy on 127.0.0.1:${TLS_PORT:-8443} in front of the node.
# Anything that talks to it needs NODE_EXTRA_CA_CERTS=<.ci-out/tls/cert.pem>.
set -euo pipefail
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

NODE_PORT="${NODE_PORT:-8000}"
TLS_PORT="${TLS_PORT:-8443}"
OUT_DIR="${OUT_DIR:-.ci-out}"
NAME="${TLS_NAME:-clevercon-tls-proxy}"
DIR="$(pwd)/${OUT_DIR}/tls"
mkdir -p "$DIR"

openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
  -keyout "$DIR/key.pem" -out "$DIR/cert.pem" 2>/dev/null
chmod 644 "$DIR/key.pem" # throwaway key; the nginx user inside the container must be able to read it

cat > "$DIR/default.conf" <<'EOF'
server {
  listen __TLS_PORT__ ssl;
  ssl_certificate /certs/cert.pem;
  ssl_certificate_key /certs/key.pem;
  location / {
    proxy_pass http://127.0.0.1:__NODE_PORT__;
    proxy_set_header Host $host;
    proxy_read_timeout 120s;
    client_max_body_size 10m;
  }
}
EOF
sed -i -e "s/__TLS_PORT__/${TLS_PORT}/" -e "s/__NODE_PORT__/${NODE_PORT}/" "$DIR/default.conf"

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --network host \
  -v "$DIR/default.conf:/etc/nginx/conf.d/default.conf:ro" \
  -v "$DIR:/certs:ro" \
  nginx:1.27-alpine@sha256:62223d644fa234c3a1cc785ee14242ec47a77364226f1c811d2f669f96dc2ac8 >/dev/null

for _ in $(seq 1 30); do
  if curl -fsS -m 5 --cacert "$DIR/cert.pem" -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}' \
    "https://127.0.0.1:${TLS_PORT}/rpc" 2>/dev/null | grep -q '"healthy"'; then
    echo "https proxy ready: https://127.0.0.1:${TLS_PORT} (trust ${DIR}/cert.pem)"
    exit 0
  fi
  sleep 2
done
docker logs --tail 40 "$NAME" >&2 || true
echo "https proxy did not come up" >&2
exit 1