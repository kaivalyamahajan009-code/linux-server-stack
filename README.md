# Linux Server Monitoring, Backup & Service Audit Stack

A small monitoring setup for one Ubuntu 24.04 server that I built to learn Docker, Prometheus, PostgreSQL, Bash and systemd.

- **Monitoring:** Node Exporter (host metrics) and cAdvisor (container metrics) are scraped by Prometheus and shown in Grafana.
- **Service audit:** `audit.sh` checks systemd services, the 5 containers and the expected ports every 5 minutes, and stores every result in PostgreSQL.
- **Backups:** `backup.sh` backs up PostgreSQL, Grafana, Prometheus and the config every night. Backup history is stored in PostgreSQL too.
- **Restore:** `restore.sh` restores a backup onto a fresh VM.
- **Scheduling:** systemd timers run the audit and the backup.

## How it fits together

```text
node-exporter (host)  ─┐
cadvisor (containers) ─┼──> prometheus ──> grafana dashboards
audit.sh .prom file   ─┘                      │
                                              │
audit.sh / backup.sh ──> postgres ────────────┘  (history tables)
```

All containers use `network_mode: host` and only listen on `127.0.0.1`, so nothing is open to the internet. I reach Grafana through an SSH tunnel.

| Service | Port |
|---|---|
| Grafana | 3000 |
| Prometheus | 9090 |
| Node Exporter | 9100 |
| cAdvisor | 8080 |
| PostgreSQL | 5432 |

`audit.sh` and `backup.sh` write their results to `.prom` files in `TEXTFILE_DIR`. Node Exporter's textfile collector picks them up, so Prometheus can alert when a service is down or a backup hasn't run.

## Folder layout

```text
compose.yaml            5 containers
.env.example            settings and passwords template
config/                 services.conf and ports.tsv (what the audit checks)
postgres/schema.sql     5 tables: audit_runs, service_checks, port_checks, backup_runs, restore_runs
prometheus/             scrape config and alert rules
grafana/                datasources and 3 dashboards (host, containers, audit/backups)
scripts/
  lib/common.sh         shared helpers (logging, lock, compose, run_sql, metrics)
  preflight.sh          checks before the first start
  bootstrap-db.sh       creates tables and the read-only grafana user
  audit.sh              service / container / port audit
  backup.sh             nightly backup + cleanup of old backups
  verify-backup.sh      test-restores a backup's database in a temporary container
  restore.sh            restore onto a fresh VM
  install-systemd.sh    installs the timers
systemd/                service and timer units
docs/restore-runbook.md restore steps
```

## Setup

On Ubuntu 24.04, as root:

```bash
apt-get update && apt-get install -y curl docker.io docker-compose-v2
systemctl enable --now docker

git clone https://github.com/kaivalyamahajan009-code/linux-server-stack /opt/linux-server-stack
cd /opt/linux-server-stack

cp .env.example .env
chmod 600 .env
nano .env        # set the 3 passwords, e.g. with: openssl rand -hex 24

chmod +x scripts/*.sh
./scripts/preflight.sh
docker compose up -d
./scripts/bootstrap-db.sh
./scripts/audit.sh
./scripts/backup.sh
./scripts/install-systemd.sh
```

Open Grafana from your laptop:

```bash
ssh -L 3000:127.0.0.1:3000 user@server-ip
# then open http://localhost:3000 and log in with GRAFANA_ADMIN_USER / GRAFANA_ADMIN_PASSWORD
```

## Day to day

```bash
# timers and logs
systemctl list-timers 'linux-server-*'
journalctl -u linux-server-audit.service -n 20
journalctl -u linux-server-backup.service -n 20

# run a job by hand
systemctl start linux-server-backup.service

# test that the latest backup can actually be restored
./scripts/verify-backup.sh "$(ls /var/backups/linux-server-stack | tail -n 1)"

# open the database
docker compose exec postgres psql -U postgres -d server_audit
```

To check another service or port, add a line to `config/services.conf` or `config/ports.tsv`. The next audit picks it up.

Useful queries:

```sql
-- last 5 audits
SELECT id, started_at, status FROM audit_runs ORDER BY id DESC LIMIT 5;

-- what was unhealthy in the latest audit
SELECT target_type, target_name, details FROM service_checks
WHERE audit_run_id = (SELECT max(id) FROM audit_runs) AND NOT is_healthy;

-- backup history
SELECT backup_id, status, total_bytes / 1024 / 1024 AS size_mb, verification_result, pruned_at
FROM backup_runs ORDER BY started_at DESC LIMIT 10;
```

## How the backup works

1. `pg_dump -Fc` of the PostgreSQL database (safe to run while Postgres is up).
2. Grafana and Prometheus are stopped for a few seconds, because Grafana's SQLite file and Prometheus' TSDB can be half-written while they run. Their volumes are tarred with a small alpine container, then both are started again.
3. The project config (including `.env`) is tarred.
4. `SHA256SUMS` is written so a damaged file can be detected later.
5. The backup is written to a `.incomplete_` folder and only renamed when everything is done.
6. Only the newest `BACKUP_KEEP_COUNT` backups are kept.

`flock` makes sure backup, verify and restore never run at the same time.

## Alerts

`prometheus/alerts.yml` has rules for: scrape target down, disk > 85 %, memory > 90 %, unhealthy service or port, audit older than 15 min, and backup older than 26 h. They show up in Prometheus at `/alerts`; I didn't set up email or Slack notifications.

## Testing checklist

Things to try on a test VM:

- [ ] `docker compose ps` shows 5 running containers and Prometheus `/targets` shows 3 targets up.
- [ ] Stop Grafana (`docker compose stop grafana`), run `audit.sh`, see it unhealthy in the dashboard and in `service_checks`. Start it again and run the audit.
- [ ] Stop Postgres and run `audit.sh`. It should fail and `server_audit_execution_success` should become 0.
- [ ] Run `backup.sh` twice with `BACKUP_KEEP_COUNT=1` and check that only one backup is left.
- [ ] Run `verify-backup.sh` on a backup, then edit a byte in one archive and check that it fails.
- [ ] Restore a backup on a second VM (see `docs/restore-runbook.md`).
- [ ] Reboot and check that the timers are still scheduled.

## Limitations

- Single server only. Backups are stored on the same disk, so copy them somewhere else if they matter.
- Grafana and Prometheus are down for a few seconds during each backup.
- Restore only works on a fresh VM. Restoring over a running stack is not supported.
