#!/usr/bin/env bash
# Run once before the first "docker compose up" to check the server is ready.

source "$(dirname "$0")/lib/common.sh"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Please run as root (sudo)."
    exit 1
fi

for cmd in docker curl tar ss flock; do
    if ! command -v "${cmd}" >/dev/null; then
        log "ERROR: ${cmd} is not installed."
        exit 1
    fi
done

if ! docker compose version >/dev/null 2>&1; then
    log "ERROR: docker compose v2 is not available."
    exit 1
fi

load_env

# cAdvisor mounts DOCKER_DATA_ROOT, so it has to match the real docker folder.
DOCKER_ROOT="$(docker info -f '{{.DockerRootDir}}')"
if [[ "${DOCKER_ROOT}" != "${DOCKER_DATA_ROOT}" ]]; then
    log "ERROR: docker uses ${DOCKER_ROOT} but .env says DOCKER_DATA_ROOT=${DOCKER_DATA_ROOT}."
    exit 1
fi

for port in 3000 9090 9100 8080 5432; do
    if [[ -n "$(ss -ltnH "sport = :${port}")" ]]; then
        log "ERROR: port ${port} is already in use."
        exit 1
    fi
done

mkdir -p "${BACKUP_DIR}" "${TEXTFILE_DIR}"
chmod 700 "${BACKUP_DIR}"
chmod 755 "${TEXTFILE_DIR}"

log "All checks passed, you can run: docker compose up -d"
