#!/usr/bin/env bash
# CleverCon baseline harness for a fresh Ubuntu EC2 host (Stage 1b).
#
# Goal: produce EVIDENCE of what works today, unmodified, on a clean machine.
# It changes nothing in the repo (only untracked files: .env, wallets.json,
# docker-compose.override.yml, which are git-ignored/excluded).
#
# Usage:
#   FORK_URL=https://github.com/<you>/clevercon.git ./baseline-ec2.sh checks
#   ./baseline-ec2.sh e2e        # full money loop on Stellar TESTNET (needs checks first)
#   ./baseline-ec2.sh contracts  # cargo fmt/clippy/test (needs Rust; heavy on small hosts)
#   ./baseline-ec2.sh down       # stop services + containers
#
# Env:
#   FORK_URL   required on first run (your fork)
#   WORKDIR    default $HOME/clevercon-baseline
#
# Security notes:
#   * The API binds 0.0.0.0:4100. Do NOT open 4100/5432/6379 in the EC2 security
#     group. Reach the API through an SSH tunnel: ssh -L 4100:localhost:4100 ...
#   * Secrets are generated fresh and written only to .env on this host.

set -uo pipefail

WORKDIR="${WORKDIR:-$HOME/clevercon-baseline}"
REPO="$WORKDIR/clevercon"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="$WORKDIR/reports/$STAMP"
RESULTS="$REPORT/results.tsv"
CMD="${1:-checks}"

mkdir -p "$REPORT"
printf 'step\tstatus\tseconds\tlog\n' > "$RESULTS"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*"; }
die()  { printf '\033[31mx %s\033[0m\n' "$*"; exit 1; }

# run_step <name> <command...> : logs output, records pass/fail + duration, never aborts.
run_step() {
  local name="$1"; shift
  local log="$REPORT/${name}.log" start end rc
  say "$name"
  start=$(date +%s)
  "$@" >"$log" 2>&1
  rc=$?
  end=$(date +%s)
  if [ $rc -eq 0 ]; then
    printf '%s\tPASS\t%s\t%s\n' "$name" $((end-start)) "$log" >> "$RESULTS"
    echo "   PASS ($((end-start))s)"
  else
    printf '%s\tFAIL(%s)\t%s\t%s\n' "$name" "$rc" $((end-start)) "$log" >> "$RESULTS"
    echo "   FAIL rc=$rc ($((end-start))s) -> $log"
    tail -n 15 "$log" | sed 's/^/   | /'
  fi
  return 0
}

setenv() { # setenv KEY VALUE (edit existing line in .env, else append)
  local k="$1" v="$2"
  if grep -q "^${k}=" "$REPO/.env"; then
    sed -i "s|^${k}=.*|${k}=${v}|" "$REPO/.env"
  else
    printf '%s=%s\n' "$k" "$v" >> "$REPO/.env"
  fi
}

preflight() {
  say "preflight"
  {
    echo "date_utc: $STAMP"
    echo "os: $(. /etc/os-release && echo "$PRETTY_NAME")"
    echo "arch: $(uname -m)"
    echo "cpus: $(nproc)"
    echo "mem_mb: $(free -m | awk '/Mem:/{print $2}')"
    echo "swap_mb: $(free -m | awk '/Swap:/{print $2}')"
    echo "disk_free_gb: $(df -BG --output=avail "$HOME" | tail -1 | tr -dc 0-9)"
  } | tee "$REPORT/host.txt"

  for bin in git docker openssl curl; do
    command -v "$bin" >/dev/null || die "missing: $bin"
  done
  docker compose version >/dev/null 2>&1 || die "docker compose plugin missing"
  docker info >/dev/null 2>&1 || die "docker daemon not reachable (is your user in the docker group?)"

  command -v node >/dev/null || die "node missing (install Node 20 via nvm; repo pins .nvmrc)"
  local major; major=$(node -v | sed 's/v\([0-9]*\).*/\1/')
  [ "$major" -ge 20 ] || die "Node >= 20 required, found $(node -v)"

  local mem; mem=$(free -m | awk '/Mem:/{print $2}')
  local swap; swap=$(free -m | awk '/Swap:/{print $2}')
  if [ $((mem + swap)) -lt 3500 ]; then
    warn "RAM+swap < 3.5GB: npm ci/tsc may be OOM-killed. Add swap (e.g. 4G) or use a t3.medium."
  fi
}

get_repo() {
  say "repo"
  if [ ! -d "$REPO/.git" ]; then
    [ -n "${FORK_URL:-}" ] || die "set FORK_URL on first run"
    mkdir -p "$WORKDIR"
    git clone "$FORK_URL" "$REPO" || die "clone failed"
  fi
  ( cd "$REPO" && git rev-parse HEAD ) | tee "$REPORT/commit.txt"
  ( cd "$REPO" && cat .nvmrc ) > "$REPORT/nvmrc.txt" 2>/dev/null || true
}

make_env() {
  say ".env + compose override"
  cd "$REPO" || die "no repo"
  if [ ! -f .env ]; then
    cp .env.example .env
    local pgpass; pgpass=$(openssl rand -hex 16)
    setenv JWT_SECRET "$(openssl rand -hex 32)"
    setenv DELEGATE_ENCRYPTION_KEY "$(openssl rand -hex 32)"
    setenv POSTGRES_PASSWORD "$pgpass"
    setenv DATABASE_URL "postgresql://clevercon:${pgpass}@localhost:5432/clevercon"
    setenv BACKEND full
    setenv VITE_BACKEND full
    chmod 600 .env
    echo "   created .env with fresh secrets (BACK UP DELEGATE_ENCRYPTION_KEY if you keep this host)"
  else
    echo "   .env exists, left untouched"
  fi

  # The repo's compose file publishes 5432/6379 on ALL interfaces with default
  # creds. Rebind to loopback with a local-only override (needs Compose >= 2.24.4).
  local cv; cv=$(docker compose version --short 2>/dev/null | sed 's/^v//')
  if [ "$(printf '%s\n2.24.4\n' "$cv" | sort -V | head -1)" = "2.24.4" ]; then
    cat > docker-compose.override.yml <<'YAML'
services:
  postgres:
    ports: !override
      - '127.0.0.1:${POSTGRES_PORT:-5432}:5432'
  redis:
    ports: !override
      - '127.0.0.1:${REDIS_PORT:-6379}:6379'
YAML
    grep -qx 'docker-compose.override.yml' .git/info/exclude || echo 'docker-compose.override.yml' >> .git/info/exclude
    echo "   loopback-only DB/Redis ports via override (compose $cv)"
  else
    warn "compose $cv < 2.24.4: cannot rebind ports; make sure the security group blocks 5432/6379"
  fi
}

install_and_db() {
  cd "$REPO" || die "no repo"
  run_step npm_ci npm ci --no-audit --no-fund
  if ! grep -q '^SERVER_SIGNING_KEY=.\+' .env; then
    setenv SERVER_SIGNING_KEY "$(node -e "console.log(require('@stellar/stellar-sdk').Keypair.random().secret())")"
  fi
  run_step compose_up docker compose up -d --wait postgres redis
  run_step db_push npm run db:push
  run_step db_seed npm run db:seed
}

quality_gates() {
  cd "$REPO" || die "no repo"
  run_step typecheck npm run typecheck
  run_step lint npm run lint
  run_step format_check npm run format:check
  run_step build npm run build
  run_step unit_tests npm test
}

summary() {
  say "summary ($REPORT)"
  column -t -s $'\t' "$RESULTS"
  echo
  echo "Attach $REPORT (host.txt, commit.txt, results.tsv, logs) to your Stage 1 findings."
}

start_services() {
  cd "$REPO" || die "no repo"
  mkdir -p "$REPORT/svc"
  say "starting api/workers/indexer (logs in $REPORT/svc)"
  npm run build -w @clevercon/api >"$REPORT/svc/api-build.log" 2>&1 || die "api build failed"
  # Run from repo root so each service finds ./.env (they do not source it in bash;
  # NETWORK_PASSPHRASE contains spaces and ';').
  nohup npm run start -w @clevercon/api      >"$REPORT/svc/api.log"     2>&1 & echo $! > "$WORKDIR/api.pid"
  nohup npm run start -w @clevercon/workers  >"$REPORT/svc/workers.log" 2>&1 & echo $! > "$WORKDIR/workers.pid"
  nohup npm run start -w @clevercon/indexer  >"$REPORT/svc/indexer.log" 2>&1 & echo $! > "$WORKDIR/indexer.pid"

  for i in $(seq 1 60); do
    if curl -fsS http://localhost:4100/ready >"$REPORT/ready.json" 2>/dev/null; then
      echo "   /ready: $(cat "$REPORT/ready.json")"
      return 0
    fi
    sleep 2
  done
  die "API never became ready; see $REPORT/svc/api.log"
}

stop_services() {
  for s in api workers indexer; do
    if [ -f "$WORKDIR/$s.pid" ]; then
      pkill -P "$(cat "$WORKDIR/$s.pid")" 2>/dev/null || true
      kill "$(cat "$WORKDIR/$s.pid")" 2>/dev/null || true
      rm -f "$WORKDIR/$s.pid"
    fi
  done
}

case "$CMD" in
  checks)
    preflight
    get_repo
    make_env
    install_and_db
    quality_gates
    summary
    ;;
  e2e)
    get_repo
    cd "$REPO" || die "no repo"
    [ -f .env ] || die "run 'checks' first"
    # Faucet wallet used by the harness (testnet only; friendbot + DEX swap).
    [ -f wallets.json ] || run_step setup_wallets npx tsx scripts/setup-wallets.ts
    run_step usdc_trustlines npx tsx scripts/add-usdc-trustlines.ts
    run_step fund_testnet_usdc npx tsx scripts/fund-testnet-usdc.ts
    start_services
    trap stop_services EXIT
    # NOTE: this hits the shared Testnet contracts in .env with a throwaway keypair.
    run_step e2e_testnet env E2E_SKIP_HIRE=1 npx tsx scripts/e2e-testnet.ts
    summary
    ;;
  contracts)
    get_repo
    command -v cargo >/dev/null || die "install Rust (rustup) first"
    rustup target add wasm32v1-none >/dev/null 2>&1 || true
    for c in agent-vault policy-verifier; do
      run_step "fmt_$c"    bash -c "cd '$REPO/contracts/$c' && cargo fmt --check"
      run_step "clippy_$c" bash -c "cd '$REPO/contracts/$c' && cargo clippy --all-targets -- -D warnings"
      run_step "test_$c"   bash -c "cd '$REPO/contracts/$c' && cargo test"
    done
    run_step build_registry_wasm bash -c "cd '$REPO/contracts/registry' && cargo build --release --target wasm32v1-none"
    summary
    ;;
  down)
    stop_services
    cd "$REPO" 2>/dev/null && docker compose down
    ;;
  *)
    die "usage: $0 [checks|e2e|contracts|down]"
    ;;
esac
