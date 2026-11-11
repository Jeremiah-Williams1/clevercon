#!/usr/bin/env bash
# Runs ON the staging host every 60 s (systemd timer, see install.sh). Writes Prometheus "textfile" metrics
# that node_exporter publishes. Prints no secrets; reads values from .env.staging with grep (never `source`).
#
# Metrics:
#   clevercon_indexer_state_age_seconds{stream}   seconds since indexer_state.updatedAt (the indexer's heartbeat)
#   clevercon_rpc_up / _latency_seconds / _latest_ledger / _retention_ledgers   from the Stellar RPC getHealth call
#   clevercon_workers_last_sweep_age_seconds      age of the last "health sweep processed" log line
#   clevercon_vault_days_left                     days until the vault contract instance expires (checked every 10 min)
#   clevercon_vault_check_ok                      1 if the last vault check worked
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(git -C "$HERE" rev-parse --show-toplevel)"
ENV="${ENV_FILE:-$ROOT/ops/staging/.env.staging}"
OUT_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
OUT="$OUT_DIR/clevercon.prom"
SWEEP_WINDOW_MIN=20          # how far back to look for the workers' sweep line
VAULT_EVERY_SECONDS=600      # vault TTL moves slowly; do not start a node process every minute
LEDGER_SECONDS=5             # Stellar closes a ledger about every 5 s

[ -r "$ENV" ] || { echo "metrics.sh: cannot read $ENV" >&2; exit 1; }
val() { grep -m1 "^$1=" "$ENV" | cut -d= -f2-; }
dc()  { timeout 25 docker compose --env-file "$ENV" -f "$ROOT/ops/staging/docker-compose.staging.yml" "$@"; }

tmp="$(mktemp "$OUT_DIR/.clevercon.XXXXXX")" || exit 1
trap 'rm -f "$tmp"' EXIT
emit() { printf '%s\n' "$*" >>"$tmp"; }
now=$(date +%s)

# 1. Indexer heartbeat -------------------------------------------------------------------------------------
emit '# HELP clevercon_indexer_state_age_seconds Seconds since the indexer last saved its cursor.'
emit '# TYPE clevercon_indexer_state_age_seconds gauge'
if rows=$(dc exec -T postgres psql -U clevercon -d clevercon -At -F '|' \
    -c 'select key, extract(epoch from (now() - "updatedAt"))::bigint from indexer_state' 2>/dev/null); then
  while IFS='|' read -r key age; do
    [ -n "${key:-}" ] || continue
    key=${key//[\"\\]/_}
    emit "clevercon_indexer_state_age_seconds{stream=\"$key\"} $age"
  done <<<"$rows"
fi

# 2. Stellar RPC ---------------------------------------------------------------------------------------------
rpc_url="$(val STELLAR_RPC_URL)"
emit '# HELP clevercon_rpc_up 1 if the Stellar RPC answers getHealth with status healthy.'
emit '# TYPE clevercon_rpc_up gauge'
if [ -n "$rpc_url" ]; then
  t0=$(date +%s.%N)
  resp=$(curl -fsS -m 8 -X POST -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}' "$rpc_url" 2>/dev/null || true)
  t1=$(date +%s.%N)
  if grep -qE '"status": *"healthy"' <<<"$resp"; then up=1; else up=0; fi
  emit "clevercon_rpc_up $up"
  emit '# HELP clevercon_rpc_latency_seconds Time the getHealth call took.'
  emit '# TYPE clevercon_rpc_latency_seconds gauge'
  emit "clevercon_rpc_latency_seconds $(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')"
  latest=$(grep -oE '"latestLedger": *[0-9]+' <<<"$resp" | head -1 | cut -d: -f2 | tr -d ' ')
  oldest=$(grep -oE '"oldestLedger": *[0-9]+' <<<"$resp" | head -1 | cut -d: -f2 | tr -d ' ')
  if [ -n "$latest" ]; then
    emit '# HELP clevercon_rpc_latest_ledger Latest ledger the RPC reports.'
    emit '# TYPE clevercon_rpc_latest_ledger gauge'
    emit "clevercon_rpc_latest_ledger $latest"
  fi
  if [ -n "$latest" ] && [ -n "$oldest" ]; then
    emit '# HELP clevercon_rpc_retention_ledgers How many ledgers of history the RPC keeps (the indexer can only catch up inside this window).'
    emit '# TYPE clevercon_rpc_retention_ledgers gauge'
    emit "clevercon_rpc_retention_ledgers $((latest - oldest))"
  fi
fi

# 3. Workers: age of the last "health sweep processed" log line ----------------------------------------------
emit '# HELP clevercon_workers_last_sweep_age_seconds Age of the last health-sweep log line (window length if none seen).'
emit '# TYPE clevercon_workers_last_sweep_age_seconds gauge'
line=$(dc logs --no-log-prefix --since "${SWEEP_WINDOW_MIN}m" workers 2>/dev/null | grep 'health sweep processed' | tail -1 || true)
ms=$(grep -oE '"time":[0-9]{13}' <<<"$line" | head -1 | cut -d: -f2 | tr -d ' ')
if [ -n "$ms" ]; then age=$((now - ms / 1000)); else age=$((SWEEP_WINDOW_MIN * 60)); fi
emit "clevercon_workers_last_sweep_age_seconds $age"

# 4. Vault TTL (cached) ----------------------------------------------------------------------------------------
cache="$OUT_DIR/vault.cache"   # not *.prom, so node_exporter ignores it
if [ ! -s "$cache" ] || [ $((now - $(stat -c %Y "$cache"))) -ge "$VAULT_EVERY_SECONDS" ]; then
  # Runs inside the api container, which already has @stellar/stellar-sdk and the contract ID and RPC URL in its env.
  days=$(dc exec -T api node --input-type=module - 2>/dev/null <<'JS' || true
import * as S from '@stellar/stellar-sdk';
const id = process.env.AGENT_VAULT_CONTRACT_ID;
const url = process.env.STELLAR_RPC_URL;
if (!id || !url) process.exit(2);
const server = new S.rpc.Server(url);
const key = S.xdr.LedgerKey.contractData(new S.xdr.LedgerKeyContractData({
  contract: new S.Address(id).toScAddress(),
  key: S.xdr.ScVal.scvLedgerKeyContractInstance(),
  durability: S.xdr.ContractDataDurability.persistent(),
}));
const res = await server.getLedgerEntries(key);
const e = res.entries[0];
if (!e || e.liveUntilLedgerSeq == null) process.exit(3);
console.log(e.liveUntilLedgerSeq - res.latestLedger);
JS
  )
  ledgers=$(grep -oE '^-?[0-9]+$' <<<"$days" | tail -1)
  if [ -n "$ledgers" ]; then
    awk -v l="$ledgers" -v s="$LEDGER_SECONDS" 'BEGIN{printf "%.2f\n", l*s/86400}' >"$cache.tmp" && mv "$cache.tmp" "$cache"
    vault_ok=1
  else
    vault_ok=0
  fi
else
  vault_ok=1
fi
emit '# HELP clevercon_vault_check_ok 1 if the last vault TTL check worked.'
emit '# TYPE clevercon_vault_check_ok gauge'
emit "clevercon_vault_check_ok $vault_ok"
if [ "$vault_ok" = 1 ] && [ -s "$cache" ]; then
  emit '# HELP clevercon_vault_days_left Days until the vault contract instance entry expires.'
  emit '# TYPE clevercon_vault_days_left gauge'
  emit "clevercon_vault_days_left $(cat "$cache")"
fi

# 5. Containers. cAdvisor cannot read Docker 29's containerd image store, so we ask Docker directly.
# Matched by compose labels; one-off `compose run` containers (the e2e) are ignored.
run_l=""; rst_l=""; sta_l=""; oom_l=""
for svc in api workers indexer postgres redis web; do
  cid=$(docker ps -aq --filter label=com.docker.compose.project=clevercon-staging \
    --filter "label=com.docker.compose.service=$svc" --filter label=com.docker.compose.oneoff=False 2>/dev/null | head -1)
  running=0; restarts=0; started=0; oom=0
  if [ -n "$cid" ]; then
    read -r r n s o < <(docker inspect -f '{{.State.Running}} {{.RestartCount}} {{.State.StartedAt}} {{.State.OOMKilled}}' "$cid" 2>/dev/null || true)
    [ "${r:-}" = true ] && running=1
    restarts=${n:-0}
    [ -n "${s:-}" ] && started=$(date -d "$s" +%s 2>/dev/null || echo 0)
    [ "${o:-}" = true ] && oom=1
  fi
  run_l+="clevercon_container_running{service=\"$svc\"} $running"$'\n'
  rst_l+="clevercon_container_restarts_total{service=\"$svc\"} $restarts"$'\n'
  sta_l+="clevercon_container_started_timestamp_seconds{service=\"$svc\"} $started"$'\n'
  oom_l+="clevercon_container_oom_killed{service=\"$svc\"} $oom"$'\n'
done
emit '# HELP clevercon_container_running 1 if the compose service container is running (0 if stopped or missing).'
emit '# TYPE clevercon_container_running gauge'
printf '%s' "$run_l" >>"$tmp"
emit '# HELP clevercon_container_restarts_total Docker restart count of the service container.'
emit '# TYPE clevercon_container_restarts_total counter'
printf '%s' "$rst_l" >>"$tmp"
emit '# HELP clevercon_container_started_timestamp_seconds Unix time the container last started.'
emit '# TYPE clevercon_container_started_timestamp_seconds gauge'
printf '%s' "$sta_l" >>"$tmp"
emit '# HELP clevercon_container_oom_killed 1 if the last stop was an out-of-memory kill.'
emit '# TYPE clevercon_container_oom_killed gauge'
printf '%s' "$oom_l" >>"$tmp"

emit '# HELP clevercon_metrics_last_run_timestamp_seconds Unix time of the last metrics.sh run.'
emit '# TYPE clevercon_metrics_last_run_timestamp_seconds gauge'
emit "clevercon_metrics_last_run_timestamp_seconds $now"

chmod 644 "$tmp"
mv "$tmp" "$OUT"
trap - EXIT
