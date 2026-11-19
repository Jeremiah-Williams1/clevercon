# Monitoring (P3)

Self-hosted Prometheus, Alertmanager and Grafana on a second small instance, watching the ephemeral staging host.
Everything is plain Docker Compose and bash, so it moves to a VPS with only the AWS-specific parts swapped (see "Moving to a VPS").
Critical alerts go to Slack.

Status: built and checked end to end on 15 Nov 2026 (see "What was checked").

## How it fits together

```
 STAGING HOST (ephemeral, no inbound ports)           MONITORING HOST (second instance, no inbound ports)
 ┌─────────────────────────────────────────┐          ┌───────────────────────────────────────────────┐
 │ node_exporter  :9100  host disk/mem/CPU │          │ Prometheus :9090 ── rules ──▶ Alertmanager    │
 │   └ reads clevercon.prom (textfile)     │◀─scrape──│   ▲ file_sd: targets/staging.json (the IP)    │──▶ Slack
 │ blackbox       :9115  GETs /health,/ready│ private │ Grafana :3000 (reach it by SSM port forward)  │
 │ metrics.sh (timer, every 60 s) ─────────┘   IPs    └───────────────────────────────────────────────┘
 └─────────────────────────────────────────┘
```

The API has no Prometheus `/metrics` endpoint, so it is watched from outside: blackbox probes `/health` and `/ready`
on localhost, and `metrics.sh` adds the checks nothing else can do (indexer heartbeat, RPC, vault expiry, per-container state).
Request, error and latency metrics per route need app-level metrics, which is a small patch for the maintainer (see "Known gaps").

## What runs where

| Where | What | Notes |
|---|---|---|
| Monitoring host (`Name=clevercon-monitoring`, t3.small, 20 GB encrypted gp3, IMDSv2) | Prometheus v3.5.0, Alertmanager v0.28.1, Grafana 12.0.2 | Compose file `ops/monitoring/docker-compose.monitoring.yml`. Ports 9090, 9093 and 3000 listen on loopback only. Metrics kept 15 days. |
| Staging host | `node_exporter` (:9100), `blackbox_exporter` (:9115), `metrics.sh` on a systemd timer | `ops/monitoring/staging-collectors/`. Listen only on the host's private IP (written to `staging-collectors/.env` by `install.sh`). |

Prometheus jobs: `prometheus`, `alertmanager`, `grafana` (the stack itself), and `staging_node`, `api_health`, `api_ready` (found through `prometheus/targets/staging.json`).

cAdvisor was tried and dropped. Docker 29 uses the containerd image store by default, and cAdvisor cannot read container layers from it
([cAdvisor issue 3643](https://github.com/google/cadvisor/issues/3643)): it saw only the host root. Per-container state now comes from `metrics.sh`.

### What `metrics.sh` writes (`/var/lib/node_exporter/textfile/clevercon.prom`, every 60 s)

| Metric | Meaning |
|---|---|
| `clevercon_indexer_state_age_seconds{stream}` | Seconds since `indexer_state.updatedAt` (the indexer saves its cursor on every good poll) |
| `clevercon_rpc_up`, `_rpc_latency_seconds`, `_rpc_latest_ledger`, `_rpc_retention_ledgers` | Stellar RPC `getHealth` from the staging host |
| `clevercon_workers_last_sweep_age_seconds` | Age of the last "health sweep processed" log line from the workers |
| `clevercon_vault_days_left`, `clevercon_vault_check_ok` | Days until the vault contract instance entry expires (checked every 10 minutes) |
| `clevercon_container_running`, `_restarts_total`, `_started_timestamp_seconds`, `_oom_killed` (label `service`) | State of api, workers, indexer, postgres, redis, web. One-off `compose run` containers (the e2e) are ignored. |
| `clevercon_metrics_last_run_timestamp_seconds` | When the script last ran |

## Files (all under `ops/monitoring/` unless noted)

| Path | Runs on | Purpose |
|---|---|---|
| `docker-compose.monitoring.yml` | monitoring host | Prometheus, Alertmanager, Grafana |
| `apply.sh` | monitoring host | Writes the secret files, recreates the stack, syncs the Grafana admin password, checks health |
| `register-target.sh` | monitoring host | `add <private-ip>`, `remove`, `show` for the staging host |
| `prometheus/prometheus.yml`, `prometheus/rules/clevercon.yml` | monitoring host | Scrape jobs and alert rules |
| `prometheus/tests/clevercon.test.yml` | CI | Unit tests for the rules (`promtool test rules`) |
| `alertmanager/alertmanager.yml`, `alertmanager/templates/clevercon.tmpl` | monitoring host | Routing, inhibit rules, Slack message wording |
| `grafana/` | monitoring host | Datasource, dashboard provisioning, one overview dashboard |
| `staging-collectors/` | staging host | Exporters compose, `blackbox.yml`, `metrics.sh`, `install.sh`, systemd timer |
| `.github/workflows/monitoring-deploy.yml` | GitHub | Launch, update, stop or terminate the monitoring host |
| `.github/workflows/staging-deploy.yml` | GitHub | Installs the collectors and registers or unregisters staging |
| `.github/workflows/staging-security.yml` | GitHub | shellcheck on the monitoring scripts and `promtool` check and tests on the rules |

Ignored by git (`ops/monitoring/.gitignore`): `secrets/`, `prometheus/targets/*.json` (except the example), `staging-collectors/.env`.

## Alerts

Critical goes to Slack. Warning stays on the dashboard ("Firing alerts" table) and in Prometheus.
Every rule has a `for:` duration, so one bad scrape never pages anyone.

| Alert | Fires when | Severity | First look |
|---|---|---|---|
| TargetDown | an exporter or the staging host cannot be scraped for 3 min | critical | Is the instance running? Security group and exporter containers on the host |
| ApiDown | `/health` fails | critical | `docker compose ps` and `logs api` on staging |
| ApiNotReady | `/ready` fails (503 only when Postgres or Redis is down from the API's view) | critical | Postgres and Redis containers |
| ContainerNotRunning | api, workers, indexer, postgres, redis or web is not running | critical | `docker compose ps`, then `logs <service>` |
| ContainerRestarting | a container restarted more than twice in 15 min | critical | `logs <service>`, `oom_killed` metric |
| IndexerHeartbeatStale | `indexer_state.updatedAt` older than 120 s | critical | `logs indexer` (poll errors, RPC) |
| IndexerHeartbeatMissing | the indexer metric does not exist at all while staging is registered (no `indexer_state` row) | critical | `logs indexer`; the contract list must contain the vault ID only |
| RpcUnreachable | Stellar RPC `getHealth` fails for 3 min | critical | RPC status page; outbound access from the host |
| VaultTtlLow | vault instance expires in under 3 days | critical | Extend the contract TTL |
| MetricsScriptStale | `metrics.sh` has not written its file for 5 min (so the indexer, RPC and vault alerts are blind) | critical | `journalctl -u clevercon-metrics.service` |
| DiskAlmostFull | under 15% free on `/` for 10 min | critical | `docker system df`, logs |
| VaultTtlGettingLow, VaultCheckFailing, WorkersSweepStale, MemoryHigh | see `rules/clevercon.yml` | warning | |

`/ready` returns 200 with status "degraded" when only the RPC is down, so `RpcUnreachable` is the only alert for that case.
When `TargetDown` fires for a host, the other staging alerts for the same host are held back (one failure, one message).
`ApiDown` holds back `ApiNotReady`.

## How alerts reach you

- Alertmanager groups by alert name: wait 10 s for the first message, 1 minute between updates to a group, repeat every 4 hours.
- A FIRING message shows the rule's summary. A RESOLVED message is a short plain sentence, for example `Container "api" is running again.`
  The wording is in `alertmanager/templates/clevercon.tmpl`; alerts not listed there fall back to `<name> is back to normal.`
- Measured: a test alert posted directly to Alertmanager reached Slack in under a minute. A real failure takes about 2 to 5 minutes to alert, because
  the chain is: probe or `metrics.sh` run (30 to 60 s) plus the rule's `for:` plus the 10 s group wait.
- An alert posted by hand without an end time resolves itself after 5 minutes, so its RESOLVED message arrives about 5 to 6 minutes later. That is normal.
- A planned staging teardown sends nothing: the target is removed before the instance is terminated.

## Dashboard

"CleverCon staging overview" in the CleverCon folder. Top row: API `/health`, API `/ready`, Stellar RPC, indexer heartbeat age,
last worker sweep age, vault days left. Then the firing alerts table, containers running, container restarts (last hour), host memory,
disk free, API probe time and Stellar RPC probe time.

## Secrets

Two GitHub **Environment secrets** on `staging`: `MONITORING_SLACK_WEBHOOK` (an incoming-webhook URL that starts with `https://hooks.slack.com/services/`)
and `MONITORING_GRAFANA_PASSWORD` (at least 8 characters). `monitoring-deploy` checks both before it launches anything, then sends them to the host,
where `apply.sh` writes `ops/monitoring/secrets/slack_url` and `grafana_admin_password` and resyncs the Grafana admin password.
Alertmanager reads the webhook from a file (`api_url_file`), so it never appears in git or in the compose file.

On AWS the values travel through SSM Run Command, so a base64 copy lands in SSM's command history, readable by anyone with SSM read access in the account.
That is acceptable while the account is only yours. On a VPS the same `apply.sh` is called over SSH and nothing is stored that way.

## One-time setup

**GitHub:** the two Environment secrets above, plus the existing `AWS_ROLE_ARN` and `AWS_REGION` variables on the `staging` Environment.

**AWS (AWS-specific; AWS CLI from your laptop):**
```bash
export AWS_REGION=us-east-1

# SSM role and instance profile for the monitoring host
aws iam create-role --role-name clevercon-monitoring-ec2 \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam attach-role-policy --role-name clevercon-monitoring-ec2 \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam create-instance-profile --instance-profile-name clevercon-monitoring-ec2
aws iam add-role-to-instance-profile --instance-profile-name clevercon-monitoring-ec2 --role-name clevercon-monitoring-ec2

# Security group with no inbound rules
VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
aws ec2 create-security-group --group-name clevercon-monitoring --description "CleverCon monitoring host, no inbound" \
  --vpc-id "$VPC" --tag-specifications 'ResourceType=security-group,Tags=[{Key=project,Value=clevercon}]'

# Staging group: exporter ports, from the monitoring group only
STG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=clevercon-staging --query 'SecurityGroups[0].GroupId' --output text)
MON=$(aws ec2 describe-security-groups --filters Name=group-name,Values=clevercon-monitoring --query 'SecurityGroups[0].GroupId' --output text)
for p in 9100 9115; do
  aws ec2 authorize-security-group-ingress --group-id "$STG" \
    --ip-permissions "IpProtocol=tcp,FromPort=$p,ToPort=$p,UserIdGroupPairs=[{GroupId=$MON,Description=prometheus-scrape}]"
done

# The deploy role may hand the monitoring role to a new instance
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
aws iam put-role-policy --role-name clevercon-staging-deploy --policy-name launch-monitoring \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"iam:PassRole\",\"Resource\":\"arn:aws:iam::$ACCOUNT:role/clevercon-monitoring-ec2\",\"Condition\":{\"StringEquals\":{\"iam:PassedToService\":\"ec2.amazonaws.com\"}}}]}"
```
The rule for port 9180 (cAdvisor) is no longer needed. If it still exists on the staging group, remove it with `aws ec2 revoke-security-group-ingress` using the same `--ip-permissions` form.
Create the incoming webhook in Slack (an app with Incoming Webhooks turned on, pointed at your alerts channel), and set the channel's notifications to "All messages" on your phone.

## Everyday use

| Task | How |
|---|---|
| Launch or update monitoring | Actions, **monitoring-deploy**, action `deploy`. It launches the host if there is none, starts it if stopped, puts this commit on it, restarts the stack and syncs the staging target. Run it after changing any file in `ops/monitoring/`. |
| Pause it (saves money) | `monitoring-deploy`, action `stop`. The disk and private IP are kept. |
| Remove it | `monitoring-deploy`, action `teardown`. The disk and the metrics history are deleted. |
| Deploy staging | `staging-deploy`, action `deploy`. After the app is up it installs the collectors and registers the host. |
| Tear down staging | `staging-deploy`, action `teardown`. It unregisters the host first. |
| Open Grafana | Port forward, then `http://localhost:3000`, user `admin`, the password from the GitHub secret |
| Open Prometheus | The same forward on port 9090, then `http://localhost:9090/targets` |

```bash
# laptop: find the monitoring host, then forward Grafana (repeat with 9090 for Prometheus)
ID=$(aws ec2 describe-instances --filters Name=tag:Name,Values=clevercon-monitoring Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].InstanceId' --output text)
aws ssm start-session --target "$ID" --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["3000"],"localPortNumber":["3000"]}'
```

If the monitoring host is not running when you deploy or tear down staging, the monitoring steps are skipped with a yellow warning and the deploy still succeeds.
`monitoring-deploy` (`deploy`) syncs the target afterwards: it registers the staging host if one is running and removes the target if not.
If staging is ever terminated by hand (console), its target stays registered, so `TargetDown` fires. That is intended, and the next `monitoring-deploy` cleans it up.

Send a test alert (on the monitoring host; it resolves itself after 5 minutes, or post it again with `"endsAt":"2020-01-01T00:00:00Z"`):
```bash
curl -s -XPOST localhost:9093/api/v2/alerts -H 'content-type: application/json' \
  -d '[{"labels":{"alertname":"SlackTest","severity":"critical"},"annotations":{"summary":"Test alert from clevercon-monitoring. Ignore."}}]'
```

Cost: a t3.small is roughly $15 a month if left on. Stop it when idle (check the current price for your region).

## What was checked

On the real hosts:
- Prometheus shows every target up; the dashboard fills in; the vault expiry call, RPC check and container metrics return real values.
- `security-check.sh` accepts the exporters only on the private IP and still fails on any other open port.
- Fire drills: stopping the API gave `ApiDown` and `ContainerNotRunning`; stopping the indexer gave `ContainerNotRunning` and `IndexerHeartbeatStale`; restarting them gave RESOLVED messages.
- A test alert and a direct webhook test both reached Slack. A staging teardown sent no alert.
- The full automation: `monitoring-deploy` from nothing, staging deploy with monitoring up (collectors installed, host registered), staging teardown (unregistered, silent),
  monitoring stopped then staging deployed (skipped with a warning), and monitoring started again (target synced).

In CI: `promtool check rules` and `promtool test rules` on every push to the staging branch (unit tests for most rules), and `shellcheck` on the scripts.

**Not drilled for real** (covered only by the unit tests or by reading the rule): `ApiNotReady`, `ContainerRestarting`, `RpcUnreachable`, `VaultTtlLow`, `MetricsScriptStale`,
`TargetDown`, `DiskAlmostFull`, `IndexerHeartbeatMissing`, `WorkersSweepStale`, `MemoryHigh`. Do these drills before relying on them.

## Troubleshooting

| Symptom | Check |
|---|---|
| Grafana shows no dashboard and its log repeats `no such column: provisioning.check_sum` | Grafana's database was left half-built (for example by running its CLI during first start). On the monitoring host: `docker compose -f docker-compose.monitoring.yml stop grafana && docker compose -f docker-compose.monitoring.yml rm -f grafana && docker volume rm clevercon-monitoring_grafanadata`, then run `monitoring-deploy`. Nothing valuable is lost: the dashboard and datasource come from files and the password is resynced. |
| Cannot log in to Grafana | The admin password is read from the file only when Grafana first creates its database. `monitoring-deploy` resyncs it from the GitHub secret, so run it again after changing the secret. |
| Grafana page is slow to load over the tunnel | It downloads several MB of JavaScript through SSM. `GF_SERVER_ENABLE_GZIP` is on to help. The first load is the slowest. |
| Slack silent | On the host, post to the webhook directly: `curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'content-type: application/json' --data '{"text":"test"}' "$(cat ops/monitoring/secrets/slack_url)"`. `200` means the webhook is fine and Alertmanager is the problem (check `docker compose logs alertmanager`, and remove any URL from the output before sharing it); `403` to `410` means Slack rejects the URL; `000` means no network path. |
| Changed `prometheus.yml` or `alertmanager.yml` but nothing changed | Both are mounted as single files, which a `git pull` replaces. Run `monitoring-deploy`, which recreates the containers. |
| A target is down | Is the instance running? Are the exporters up on the private IP (`ss -ltn` on staging)? Is the exporter port open from the monitoring group in the staging security group? |
| Indexer heartbeat alert, or the `poll error: filter 1 invalid` log line | `INDEXER_CONTRACT_IDS` must hold the vault ID only (confirmed by the maintainer). A second ID breaks the RPC call. |
| `clevercon-metrics.service` fails | `journalctl -u clevercon-metrics.service -n 30`. The unit runs as the owner of the repo (`install.sh` sets it); `metrics.sh` needs Docker access. |

## Known gaps

- **Alerts not drilled for real:** see "What was checked".
- **Nobody is told if the monitoring host itself dies.** A cheap fix later: an external dead man's switch that alerts when the pings stop.
- **No request, error or latency metrics per route.** The API has no `/metrics` endpoint. This needs a small patch from the maintainer (`prom-client` and a route).
- **No per-container CPU or memory graphs** since cAdvisor was dropped. `clevercon_container_oom_killed` exists but has no alert yet.
- **Not alerts yet:** memory per container, queue depth and oldest job age (Redis/BullMQ), Postgres connections and slow queries, RPC error rate, edge metrics (VPS only).
  Collect a baseline first, then decide.
- **Warnings are not sent to Slack;** they appear only on the dashboard and in Prometheus.
- **Logs are not collected.** Loki can follow once the metrics are trusted.
- **Vault expiry** checks the contract instance entry only, not every storage entry (partly addresses F6).
- **Secrets pass through SSM command history** on AWS (see "Secrets").
- **Image versions are pinned by tag,** not digest, and GitHub Actions are pinned by tag, not commit hash. Bump them from time to time.
- **No runbook links in alerts yet** (the "First look" column is a stopgap; proper runbooks come in P7).
- **No backups of Prometheus or Grafana data.** Config is in git; metric history is lost on `teardown` and kept 15 days otherwise.
- **`monitoring-deploy` and `staging-deploy` share one concurrency group,** so they queue behind each other.
- **A `staging-deploy` run needs the `AWS` role to reach the monitoring host over SSM;** if that fails the monitoring steps only warn.

## Moving to a VPS

Portable as is: the compose files, Prometheus, Alertmanager and Grafana config, the rules and their tests, `apply.sh`, `register-target.sh`, the collectors and `metrics.sh`
(`install.sh` already falls back to the default-route IP when not on EC2).

AWS-specific and to be replaced:
- **Security groups:** become firewall rules (`ufw` or the provider's) allowing 9100 and 9115 from the monitoring host's IP only.
- **SSM transport:** the workflows reach hosts through SSM Run Command. On a VPS they would call the same scripts over SSH, passing the secrets as environment variables to `apply.sh`.
- **Launch and terminate:** `monitoring-deploy` launches EC2 instances. On a VPS the host is created once by hand or with the provider's tooling.
- **IAM roles and policies:** not needed.