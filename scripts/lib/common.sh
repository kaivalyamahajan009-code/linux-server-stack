#!/usr/bin/env bash
# Shared helpers sourced by every script in scripts/.

set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS_DIR="${PROJECT_ROOT}/scripts"
CONFIG_DIR="${PROJECT_ROOT}/config"
LOCK_DIR="/run/lock/linux-server-stack"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

load_env() {
    if [[ ! -f "${PROJECT_ROOT}/.env" ]]; then
        log "ERROR: .env not found. Copy .env.example to .env first."
        exit 1
    fi
    set -a
    # shellcheck source=/dev/null
    source "${PROJECT_ROOT}/.env"
    set +a
}

# Backup, verify and restore share one lock so they never touch the volumes at the same time.
take_lock() {
    local name="$1"
    mkdir -p "${LOCK_DIR}"
    exec 9>"${LOCK_DIR}/${name}.lock"
    if ! flock -n 9; then
        log "Another ${name} job is already running, exiting."
        exit 1
    fi
}

# systemd runs the scripts from any directory, so always point compose at the project.
compose() {
    docker compose --project-directory "${PROJECT_ROOT}" --env-file "${PROJECT_ROOT}/.env" "$@"
}

# Usage: run_sql "INSERT ... VALUES (:'name')" -v name=value
# Values are passed with psql -v so they get quoted properly instead of pasted into the SQL.
run_sql() {
    local sql="$1"
    shift
    echo "${sql}" | compose exec -T postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
        -v ON_ERROR_STOP=1 -q -t -A "$@"
}

wait_for_postgres() {
    local db="${1:-${POSTGRES_DB}}"
    for _ in $(seq 1 30); do
        if compose exec -T postgres pg_isready -U "${POSTGRES_USER}" -d "${db}" -h 127.0.0.1 >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    log "ERROR: PostgreSQL did not become ready in 30 seconds."
    return 1
}

# Write to a temp file and rename, so node-exporter never reads a half-written file.
write_metrics() {
    local file="$1"
    local content="$2"
    mkdir -p "${TEXTFILE_DIR}"
    # node-exporter runs as nobody, so it can only read this folder if it is world-readable
    chmod 755 "${TEXTFILE_DIR}"
    local tmp="${TEXTFILE_DIR}/.${file}.tmp"
    echo "${content}" > "${tmp}"
    chmod 644 "${tmp}"
    mv "${tmp}" "${TEXTFILE_DIR}/${file}"
}

# On failure keep the old "last success" timestamp, so the stale-job alert still works.
write_failure_metrics() {
    local job="$1"
    local file="server_${job}.prom"
    local last_ok
    last_ok="$(awk "/^server_${job}_last_success_timestamp_seconds/ {print \$2}" "${TEXTFILE_DIR}/${file}" 2>/dev/null || true)"
    write_metrics "${file}" "server_${job}_last_success_timestamp_seconds ${last_ok:-0}
server_${job}_execution_success 0"
}

check_backup_files() {
    local dir="$1"
    if [[ ! -d "${dir}" ]]; then
        log "ERROR: backup folder ${dir} not found."
        return 1
    fi
    for f in postgres.dump grafana.tar.gz prometheus.tar.gz config.tar.gz SHA256SUMS; do
        if [[ ! -f "${dir}/${f}" ]]; then
            log "ERROR: ${f} is missing from ${dir}."
            return 1
        fi
    done
    if ! (cd "${dir}" && sha256sum --quiet -c SHA256SUMS); then
        log "ERROR: checksum mismatch in ${dir}."
        return 1
    fi
}
