#!/usr/bin/env bash
# Tests a backup by restoring its database dump into a temporary postgres container.
# Usage: ./scripts/verify-backup.sh <BACKUP_ID>

source "$(dirname "$0")/lib/common.sh"

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <BACKUP_ID>"
    exit 1
fi

BACKUP_ID="$1"
take_lock maintenance
load_env

DIR="${BACKUP_DIR}/${BACKUP_ID}"
TEST_CONTAINER="verify_${BACKUP_ID}"
PG_IMAGE="postgres:17.4-bookworm"

check_backup_files "${DIR}"
log "Checksums OK for ${BACKUP_ID}"

trap 'docker rm -f -v "${TEST_CONTAINER}" >/dev/null 2>&1 || true' EXIT

docker run -d --name "${TEST_CONTAINER}" --network none \
    -e POSTGRES_PASSWORD=test -e POSTGRES_DB=verify_db "${PG_IMAGE}" >/dev/null

# The image first starts a temporary socket-only server to run initdb, so check over TCP
# to wait for the real server.
ready=0
for _ in $(seq 1 30); do
    if docker exec "${TEST_CONTAINER}" pg_isready -h 127.0.0.1 -U postgres -d verify_db >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 1
done

if [[ "${ready}" -ne 1 ]]; then
    log "ERROR: test database did not start."
    exit 1
fi

docker exec -i "${TEST_CONTAINER}" pg_restore -U postgres -d verify_db --exit-on-error --no-owner --no-acl \
    < "${DIR}/postgres.dump"

TABLES="$(docker exec "${TEST_CONTAINER}" psql -U postgres -d verify_db -t -A -c \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';")"
AUDIT_ROWS="$(docker exec "${TEST_CONTAINER}" psql -U postgres -d verify_db -t -A -c "SELECT count(*) FROM audit_runs;")"

if [[ "${TABLES}" -lt 5 ]]; then
    log "ERROR: expected 5 tables in the restored database, found ${TABLES}."
    exit 1
fi

run_sql "UPDATE backup_runs SET verification_result = 'verified_ok' WHERE backup_id = :'id';" -v id="${BACKUP_ID}"
log "Backup ${BACKUP_ID} is good: ${TABLES} tables, ${AUDIT_ROWS} audit runs restored."
