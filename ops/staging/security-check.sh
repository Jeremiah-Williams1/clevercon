#!/usr/bin/env bash
# Run on the staging host. PASS/FAIL lockdown checks; prints no secret values.
set -uo pipefail
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"; cd "$ROOT" || exit 1
ENV=ops/staging/.env.staging; IMG=clevercon-staging:local
dc() { docker compose --env-file "$ENV" -f ops/staging/docker-compose.staging.yml "$@"; }
val() { grep -m1 "^$1=" "$ENV" | cut -d= -f2-; }
fail=0
pass() { echo "PASS  $*"; }; bad() { echo "FAIL  $*"; fail=1; }; warn() { echo "WARN  $*"; }

# 1. Only loopback listeners (ssh on :22 is a warning; the security group must block it)
open=$(ss -ltnH | awk '{print $4}' | grep -vE '^(127\.|\[::1\])' || true)
other=$(echo "$open" | grep -vE ':22$' || true)
[ -z "$other" ] && pass "no non-loopback listeners" || bad "listening beyond loopback: $(echo $other)"
echo "$open" | grep -qE ':22$' && warn "port 22 is listening"

# 2. env file permissions
[ "$(stat -c %a "$ENV")" = "600" ] && pass ".env.staging is mode 600" || bad ".env.staging is not mode 600"

# 3. app containers do not run as root
for s in api workers indexer web; do
  uid=$(dc exec -T "$s" id -u 2>/dev/null || true)
  if [ -z "$uid" ]; then bad "$s is not running"
  elif [ "$uid" = "0" ]; then bad "$s runs as root"
  else pass "$s runs as uid $uid"; fi
done

# 4. no secrets baked into the image (metadata, history, or files)
dump="$(docker image inspect "$IMG"; docker history --no-trunc "$IMG")"; leak=0
for k in JWT_SECRET DELEGATE_ENCRYPTION_KEY POSTGRES_PASSWORD REDIS_PASSWORD; do
  v=$(val "$k"); [ -n "$v" ] && grep -qF -- "$v" <<<"$dump" && { leak=1; echo "      $k value found in image metadata"; }
done
files=$(docker run --rm --entrypoint sh "$IMG" -c 'ls /app/.env /app/wallets.json 2>/dev/null' || true)
[ -n "$files" ] && { leak=1; echo "      found in image: $files"; }
[ "$leak" = 0 ] && pass "no secrets in the image" || bad "secrets or secret files in the image"

# 5. app settings
[ -n "$(val CORS_ORIGINS)" ] && pass "CORS_ORIGINS is set" || bad "CORS_ORIGINS is empty"
[ "$(val JWT_SECRET | wc -c)" -ge 33 ] && pass "JWT_SECRET length ok" || bad "JWT_SECRET is short or missing"
grep -q "^TRUST_PROXY=" "$ENV" && pass "TRUST_PROXY is set" || bad "TRUST_PROXY is missing"

# 6. IMDSv2 required (the old v1 request must be refused with 401)
code=$(curl -s -m 3 -o /dev/null -w '%{http_code}' http://169.254.169.254/latest/meta-data/ || true)
case "$code" in 401) pass "IMDSv2 required";; 200) bad "IMDSv1 still allowed";; *) warn "could not test IMDS (code $code)";; esac

[ "$fail" = 0 ] && echo -e "\nAll checks passed." || echo -e "\nSome checks FAILED."
exit "$fail"