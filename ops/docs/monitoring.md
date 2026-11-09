# Monitoring (P3)

Self-hosted Prometheus, Alertmanager and Grafana on a second small instance, watching the ephemeral staging host.
Everything is plain Docker Compose and bash, so it moves to a VPS unchanged. Alerts go to Slack.

## How it fits together

```
 STAGING HOST (ephemeral, no inbound ports)            MONITORING HOST (second instance, no inbound ports)
 ┌──────────────────────────────────────────┐          ┌───────────────────────────────────────────────┐
 │ node_exporter :9100  host disk/mem/CPU   │          │ Prometheus :9090 ── rules ──▶ Alertmanager    │
 │   └ reads clevercon.prom (textfile)      │◀─scrape──│   ▲ file_sd: targets/staging.json (the IP)    │──▶ Slack
 │ cAdvisor      :9180  per-container stats │ private  │ Grafana :3000  (SSM port forward to view)     │
 │ blackbox      :9115  GETs /health /ready │   IPs    └───────────────────────────────────────────────┘
 │ metrics.sh (timer, every 60 s) ──────────┘
 └──────────────────────────────────────────┘
```

The API has no Prometheus `/metrics` endpoint (checked in the repo), so we watch it from outside: blackbox probes
`/health` and `/ready`, cAdvisor reports each container, and `metrics.sh` adds the checks nothing else can do.
Request rates, error rates and latency per route need app-level metrics, which is a small patch for the maintainer later.

## Files (all under `ops/monitoring/`)

| Path | Runs on | Purpose |
|---|---|---|
| `docker-compose.monitoring.yml` | monitoring host | Prometheus, Alertmanager, Grafana; loopback-only ports |
| `prometheus/prometheus.yml` | monitoring host | scrape jobs; staging found through `file_sd` |
| `prometheus/rules/clevercon.yml` | monitoring host | alert rules |
| `prometheus/tests/clevercon.test.yml` | laptop / CI | unit tests for the rules (`promtool test rules`) |
| `alertmanager/alertmanager.yml` | monitoring host | critical goes to Slack, warnings are kept but not sent |
| `grafana/` | monitoring host | datasource, dashboard provisioning, one overview dashboard |
| `register-target.sh` | monitoring host | `add <ip>` / `remove` / `show` for the staging host |
| `staging-collectors/` | staging host | exporters compose, `blackbox.yml`, `metrics.sh`, `install.sh`, systemd timer |

## Alerts

Critical goes to Slack. Warning stays on the dashboard (Grafana table "Firing alerts").

| Alert | Fires when | Severity |
|---|---|---|
| TargetDown | an exporter or the host cannot be scraped for 3 min | critical |
| ApiDown | `/health` fails for 2 min | critical |
| ApiNotReady | `/ready` fails for 3 min (it returns 503 only when Postgres or Redis is down) | critical |
| ContainerMissing | api, workers, indexer, postgres or redis is not running | critical |
| ContainerRestarting | a container started more than twice in 15 min | critical |
| IndexerHeartbeatStale | `indexer_state.updatedAt` older than 120 s | critical |
| RpcUnreachable | Stellar RPC `getHealth` fails for 3 min | critical |
| VaultTtlLow | vault instance expires in under 3 days | critical |
| MetricsScriptStale | `metrics.sh` has not written its file for 5 min (so the three alerts above are blind) | critical |
| DiskAlmostFull | under 15% free on `/` for 10 min | critical |
| VaultTtlGettingLow, VaultCheckFailing, WorkersSweepStale, MemoryHigh | see rules file | warning |

`/ready` reports "degraded" (still HTTP 200) when only the RPC is down, so `RpcUnreachable` is the only alert for that.
If `TargetDown` fires for a host, the other staging alerts for that host are held back (inhibit rule), so one failure gives one message.

## First-time setup

**Monitoring host** (second instance; the launch workflow `monitoring-deploy.yml` comes next):
```bash
cd ~/clevercon/ops/monitoring
install -d -m 700 secrets                       # the folder keeps other users out
read -rsp 'Slack webhook URL: ' u; printf '%s' "$u" > secrets/slack_url; unset u
openssl rand -base64 24 > secrets/grafana_admin_password
chmod 644 secrets/*                             # the containers run as other users and must read these
docker compose -f docker-compose.monitoring.yml up -d
```
Both secret files are ignored by git (`ops/monitoring/.gitignore`). Never paste the webhook URL into chat or git.

**Staging host**, after the stack is up:
```bash
cd ~/clevercon && ops/monitoring/staging-collectors/install.sh     # prints the private IP
```

**Monitoring host**, register the staging host:
```bash
ops/monitoring/register-target.sh add <private-ip>
```

**AWS**: allow TCP 9100, 9115 and 9180 into the staging security group from the monitoring security group only.
The monitoring group needs no inbound rules. (To be scripted in `monitoring-deploy.yml`.)

**View Grafana** (laptop): SSM port forward to the monitoring instance, port 3000, then open `http://localhost:3000`
(user `admin`, password from `secrets/grafana_admin_password`).

**Teardown**: run `register-target.sh remove` on the monitoring host before terminating staging. The series disappear
and no "host down" alert fires; Slack will show "resolved" for anything that was firing.

## What was tested, and what was not

Tested in a sandbox before handing over:
- `promtool check rules`, `promtool check config` and `amtool check-config` pass; `shellcheck` passes on the three scripts.
- `promtool test rules`: ApiDown, IndexerHeartbeatStale (and no false alert when healthy), RpcUnreachable,
  MetricsScriptStale, ContainerMissing, TargetDown, VaultTtlLow and VaultTtlGettingLow fire at the right time.
- `metrics.sh` run against fake `docker` and `curl` commands: correct values, vault cache reused, and the failure case
  (RPC down, no logs, no rows) gives `rpc_up 0` and the sweep age set to the window length. The output passes `promtool check metrics`.
- The vault ledger key builds with `@stellar/stellar-sdk` 14.6.1.

**Not tested** (no Docker daemon and no access to the Testnet RPC in the sandbox). These are what the P3 gate must prove on real hosts:
- The containers start, the exporters answer on the private IP, and Prometheus shows all targets UP.
- cAdvisor really exposes the `container_label_com_docker_compose_*` labels (`ContainerMissing` and `ContainerRestarting` depend on them).
- The live vault TTL call (`getLedgerEntries` on the contract instance). It watches the instance entry only, not every storage entry.
- Real RPC `getHealth` field names (`status`, `latestLedger`, `oldestLedger`).
- Slack delivery.
- Image versions are pinned to ones I know exist; check for newer releases and pin by digest when you can.

## Known gaps

- `ops/staging/security-check.sh` will report FAIL ("listening beyond loopback") for 9100, 9115 and 9180. It needs an
  allow-list for exactly those ports on the private IP. That is a change to an existing file, so it should be a separate, small commit.
- If Postgres is down, the indexer age metric has no value (not a high one), so `IndexerHeartbeatStale` stays quiet; `ApiNotReady` and `ContainerMissing` cover that case.
- Nobody is told if the monitoring host itself dies. A cheap fix later: an external "dead man's switch" ping.
- The Slack alert has no runbook link yet; runbooks come in P7.
- Memory, queue depth, Postgres connections and edge metrics are not alerts yet: collect a baseline first, then decide.
