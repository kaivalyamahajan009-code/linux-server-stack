#!/usr/bin/env bash
# Checks systemd services, docker containers and listening ports.
# Saves every result in PostgreSQL and exports health metrics for Prometheus.

source "$(dirname "$0")/lib/common.sh"

take_lock audit
load_env

RUN_ID=""
ALL_HEALTHY=1
METRICS=""

on_exit() {
    if [[ $? -ne 0 ]]; then
        log "Audit failed."
        if [[ -n "${RUN_ID}" ]]; then
            run_sql "UPDATE audit_runs SET status = 'failed', ended_at = now() WHERE id = ${RUN_ID};" || true
        fi
        write_failure_metrics audit
    fi
}
trap on_exit EXIT

# args: type name active_state substate is_healthy details
save_service_check() {
    run_sql "INSERT INTO service_checks (audit_run_id, target_type, target_name, active_state, substate, is_healthy, details)
             VALUES (${RUN_ID}, :'type', :'name', :'state', :'sub', :'healthy', :'details');" \
        -v type="$1" -v name="$2" -v state="$3" -v sub="$4" -v healthy="$5" -v details="$6"

    if [[ "$5" == "true" ]]; then
        METRICS+="server_audit_service_healthy{target=\"$2\",type=\"$1\"} 1"$'\n'
    else
        METRICS+="server_audit_service_healthy{target=\"$2\",type=\"$1\"} 0"$'\n'
        ALL_HEALTHY=0
    fi
}

wait_for_postgres
RUN_ID="$(run_sql "INSERT INTO audit_runs (hostname, status) VALUES (:'host', 'running') RETURNING id;" -v host="$(hostname)")"
log "Started audit run ${RUN_ID}"

# systemd services listed in config/services.conf
while read -r unit; do
    [[ -z "${unit}" || "${unit}" == \#* ]] && continue

    state="$(systemctl is-active "${unit}" || true)"
    sub="$(systemctl show -p SubState --value "${unit}" || true)"
    healthy="false"
    [[ "${state}" == "active" ]] && healthy="true"

    save_service_check systemd "${unit}" "${state}" "${sub}" "${healthy}" "${state} (${sub})"
done < "${CONFIG_DIR}/services.conf"

# docker containers from compose.yaml
for svc in postgres grafana prometheus node-exporter cadvisor; do
    cid="$(compose ps -q -a "${svc}")"
    if [[ -z "${cid}" ]]; then
        save_service_check container "${svc}" "missing" "" false "container does not exist"
        continue
    fi

    status="$(docker inspect -f '{{.State.Status}}' "${cid}")"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cid}")"
    healthy="false"
    if [[ "${status}" == "running" && "${health}" != "unhealthy" ]]; then
        healthy="true"
    fi

    save_service_check container "${svc}" "${status}" "${health}" "${healthy}" "${status}, health: ${health}"
done

# ports listed in config/ports.tsv (name, address, port, optional http url)
while IFS=$'\t' read -r name addr port url; do
    [[ -z "${name}" || "${name}" == \#* ]] && continue

    listening="false"
    http_code=""
    error=""

    if [[ -n "$(ss -ltnH "src ${addr}:${port}")" ]]; then
        listening="true"
    else
        error="nothing listening on ${addr}:${port}"
    fi

    if [[ "${listening}" == "true" && "${url}" != "-" ]]; then
        http_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${url}" || true)"
        if [[ ! "${http_code}" =~ ^[23] ]]; then
            error="HTTP ${http_code}"
        fi
    fi

    healthy="false"
    [[ -z "${error}" ]] && healthy="true"

    run_sql "INSERT INTO port_checks (audit_run_id, name, address, port, is_listening, http_status, is_healthy, error_message)
             VALUES (${RUN_ID}, :'name', :'addr', :'port', :'listening', NULLIF(:'code', '')::int, :'healthy', NULLIF(:'error', ''));" \
        -v name="${name}" -v addr="${addr}" -v port="${port}" -v listening="${listening}" \
        -v code="${http_code}" -v healthy="${healthy}" -v error="${error}"

    if [[ "${healthy}" == "true" ]]; then
        METRICS+="server_audit_port_healthy{name=\"${name}\",port=\"${port}\"} 1"$'\n'
    else
        METRICS+="server_audit_port_healthy{name=\"${name}\",port=\"${port}\"} 0"$'\n'
        ALL_HEALTHY=0
    fi
done < "${CONFIG_DIR}/ports.tsv"

run_sql "UPDATE audit_runs SET status = 'completed', ended_at = now() WHERE id = ${RUN_ID};"

write_metrics server_audit.prom "server_audit_last_success_timestamp_seconds $(date +%s)
server_audit_execution_success 1
server_audit_overall_health ${ALL_HEALTHY}
${METRICS}"

log "Audit ${RUN_ID} done, all healthy: ${ALL_HEALTHY}"
