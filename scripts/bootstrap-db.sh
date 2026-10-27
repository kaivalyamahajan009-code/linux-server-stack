#!/usr/bin/env bash
# Creates the tables and a read-only "grafana_reader" user for Grafana.
# Safe to run again, everything uses IF NOT EXISTS.

source "$(dirname "$0")/lib/common.sh"

load_env
wait_for_postgres

log "Applying postgres/schema.sql"
compose exec -T postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -v ON_ERROR_STOP=1 -q \
    < "${PROJECT_ROOT}/postgres/schema.sql"

# Grafana only needs to read the history tables, so it gets its own user with SELECT only.
log "Setting up grafana_reader"
compose exec -T postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -v ON_ERROR_STOP=1 -q \
    -v reader_pwd="${GRAFANA_DB_READER_PASSWORD}" -v db="${POSTGRES_DB}" <<'SQL'
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana_reader') THEN
        CREATE ROLE grafana_reader LOGIN;
    END IF;
END
$$;

ALTER ROLE grafana_reader WITH PASSWORD :'reader_pwd';
GRANT CONNECT ON DATABASE :"db" TO grafana_reader;
GRANT USAGE ON SCHEMA public TO grafana_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO grafana_reader;
SQL

log "Database ready."
