#!/usr/bin/env bash
# Restores a backup onto a fresh VM where the stack has never been started.
# Usage: ./scripts/restore.sh <BACKUP_ID>

source "$(dirname "$0")/lib/common.sh"

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <BACKUP_ID>"
    exit 1
fi

BACKUP_ID="$1"
take_lock maintenance
load_env

DIR="${BACKUP_DIR}/${BACKUP_ID}"
HELPER_IMAGE="alpine:3.21.3"
START_TIME="$(date -Iseconds)"

check_backup_files "${DIR}"

# This script only fills empty volumes. It does not try to merge into or replace live data.
if [[ -n "$(docker volume ls -q --filter "name=${COMPOSE_PROJECT_NAME}_")" ]]; then
    log "ERROR: volumes for ${COMPOSE_PROJECT_NAME} already exist. Run this on a fresh VM."
    exit 1
fi

log "Creating containers and empty volumes"
compose create

for name in grafana prometheus; do
    # Grafana runs as uid 472, Prometheus as 65534. The volume is root-owned after
    # extract, and both need to create files there (sqlite journal, tsdb wal).
    if [[ "${name}" == "grafana" ]]; then
        owner="472:472"
    else
        owner="65534:65534"
    fi
    log "Restoring ${name} volume"
    docker run --rm \
        -v "${COMPOSE_PROJECT_NAME}_${name}_data:/data" \
        -v "${DIR}:/backup:ro" \
        "${HELPER_IMAGE}" \
        sh -c "tar -xzf /backup/${name}.tar.gz -C /data && chown -R ${owner} /data"
done

log "Restoring PostgreSQL database"
compose up -d postgres
wait_for_postgres
compose exec -T postgres pg_restore -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" --exit-on-error --no-owner --no-acl \
    < "${DIR}/postgres.dump"

"${SCRIPTS_DIR}/bootstrap-db.sh"

log "Starting the full stack"
compose up -d

run_sql "INSERT INTO restore_runs (backup_id, hostname, started_at, ended_at, status)
         VALUES (:'id', :'host', :'start', now(), 'completed');" \
    -v id="${BACKUP_ID}" -v host="$(hostname)" -v start="${START_TIME}"

# The dump was taken while this backup's own row still said 'running'.
run_sql "UPDATE backup_runs SET status = 'completed', ended_at = coalesce(ended_at, now()) WHERE backup_id = :'id';" \
    -v id="${BACKUP_ID}"

log "Restore of ${BACKUP_ID} done. Open Grafana and check the dashboards."
