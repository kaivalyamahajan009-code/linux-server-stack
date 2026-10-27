# Restoring a backup on a new VM

`restore.sh` only restores onto a fresh VM. It stops if the stack's Docker volumes already exist, so it can't overwrite live data. It has to be a separate VM because all services use fixed ports on the host.

## What is in a backup

Each backup is a folder in `/var/backups/linux-server-stack/backup_<date>_<time>/`:

| File | Contents |
|---|---|
| `postgres.dump` | `pg_dump -Fc` of the `server_audit` database |
| `grafana.tar.gz` | Grafana volume (SQLite database, plugins) |
| `prometheus.tar.gz` | Prometheus volume (TSDB) |
| `config.tar.gz` | compose.yaml, .env, config, scripts, dashboards, systemd units |
| `SHA256SUMS` | checksums of the 4 files above |

## Steps

1. Install Docker on the new Ubuntu 24.04 VM:

   ```bash
   apt-get update && apt-get install -y curl docker.io docker-compose-v2
   systemctl enable --now docker
   ```

2. Copy the backup folder over and unpack the config:

   ```bash
   mkdir -p /var/backups/linux-server-stack /opt/linux-server-stack
   scp -r user@old-server:/var/backups/linux-server-stack/<BACKUP_ID> /var/backups/linux-server-stack/
   tar -xzf /var/backups/linux-server-stack/<BACKUP_ID>/config.tar.gz -C /opt/linux-server-stack
   cd /opt/linux-server-stack
   ```

3. (Optional) Test the backup first:

   ```bash
   ./scripts/verify-backup.sh <BACKUP_ID>
   ```

4. Restore:

   ```bash
   ./scripts/restore.sh <BACKUP_ID>
   ```

   This checks the checksums, creates empty volumes, unpacks Grafana and Prometheus into them, restores the database dump, runs `bootstrap-db.sh`, starts all containers and records the restore in `restore_runs`.

5. Turn the timers back on:

   ```bash
   ./scripts/install-systemd.sh
   ```

6. Open Grafana through the SSH tunnel and check that the old dashboards, metrics and audit history are there.

If something fails halfway, delete the VM (or run `docker compose down -v`) and start again from step 2.
