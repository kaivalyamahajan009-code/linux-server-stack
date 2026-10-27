#!/usr/bin/env bash
# Daily backup of PostgreSQL, Grafana, Prometheus and the project config.
# Old backups beyond BACKUP_KEEP_COUNT are deleted.

source "$(dirname "$0")/lib/common.sh"

take_lock maintenance
load_env

BACKUP_ID="backup_$(date +%Y%m%d_%H%M%S)"
WORK_DIR="${BACKUP_DIR}/.incomplete_${BACKUP_ID}"
FINAL_DIR="${BACKUP_DIR}/${BACKUP_ID}"
START_TIME="$(date +%s)"
HELPER_IMAGE="alpine:3.21.3"

on_exit() {
    if [[ $? -ne 0 ]]; then
        log "Backup ${BACKUP_ID} failed."
        compose start grafana prometheus || true
        run_sql "UPDATE backup_runs SET status = 'failed', ended_at = now(), error_message = 'backup.sh failed, check journalctl' WHERE backup_id = :'id';" \
            -v id="${BACKUP_ID}" || true
        rm -rf "${WORK_DIR}"
        write_failure_metrics backup
    fi
}
trap on_exit EXIT

log "Starting ${BACKUP_ID}"
mkdir -p "${WORK_DIR}"

wait_for_postgres
run_sql "INSERT INTO backup_runs (backup_id, hostname, backup_dir, status) VALUES (:'id', :'host', :'dir', 'running');" \
    -v id="${BACKUP_ID}" -v host="$(hostname)" -v dir="${FINAL_DIR}"

log "Dumping PostgreSQL"
compose exec -T postgres pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -Fc > "${WORK_DIR}/postgres.dump"

# Grafana (SQLite) and Prometheus (TSDB) keep writing to disk while running,
# so they are stopped for a few seconds to get a clean copy of their volumes.
log "Stopping Grafana and Prometheus to copy their volumes"
compose stop grafana prometheus
for name in grafana prometheus; do
    docker run --rm \
        -v "${COMPOSE_PROJECT_NAME}_${name}_data:/data:ro" \
        -v "${WORK_DIR}:/backup" \
        "${HELPER_IMAGE}" tar -czf "/backup/${name}.tar.gz" -C /data .
done
compose start grafana prometheus

tar -czf "${WORK_DIR}/config.tar.gz" -C "${PROJECT_ROOT}" \
    compose.yaml .env config postgres prometheus grafana scripts systemd

(cd "${WORK_DIR}" && sha256sum postgres.dump grafana.tar.gz prometheus.tar.gz config.tar.gz > SHA256SUMS)

# Only rename once everything is written, so a half-finished backup never looks like a real one.
mv "${WORK_DIR}" "${FINAL_DIR}"

END_TIME="$(date +%s)"
DURATION=$((END_TIME - START_TIME))
SIZE="$(du -sb "${FINAL_DIR}" | cut -f1)"

run_sql "UPDATE backup_runs SET status = 'completed', ended_at = now(), total_bytes = :'size' WHERE backup_id = :'id';" \
    -v id="${BACKUP_ID}" -v size="${SIZE}"

write_metrics server_backup.prom "server_backup_last_success_timestamp_seconds ${END_TIME}
server_backup_execution_success 1
server_backup_last_duration_seconds ${DURATION}
server_backup_last_bytes ${SIZE}"

# Folder names start with the date, so sorting by name = oldest first.
ls -1d "${BACKUP_DIR}"/backup_* | head -n -"${BACKUP_KEEP_COUNT}" | while read -r old; do
    log "Removing old backup $(basename "${old}")"
    rm -rf "${old}"
    run_sql "UPDATE backup_runs SET pruned_at = now() WHERE backup_id = :'id';" -v id="$(basename "${old}")"
done

log "Backup ${BACKUP_ID} finished in ${DURATION}s (${SIZE} bytes)"
