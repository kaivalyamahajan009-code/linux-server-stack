-- Tables for audit results and backup/restore history.
-- Uses IF NOT EXISTS so bootstrap-db.sh can be run again safely.

CREATE TABLE IF NOT EXISTS audit_runs (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    hostname TEXT NOT NULL,
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at TIMESTAMPTZ,
    status TEXT NOT NULL CHECK (status IN ('running', 'completed', 'failed')),
    summary_error TEXT
);

-- one row per systemd service or container checked in a run
CREATE TABLE IF NOT EXISTS service_checks (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    audit_run_id BIGINT NOT NULL REFERENCES audit_runs(id) ON DELETE CASCADE,
    target_type TEXT NOT NULL CHECK (target_type IN ('systemd', 'container')),
    target_name TEXT NOT NULL,
    active_state TEXT NOT NULL,
    substate TEXT,
    is_healthy BOOLEAN NOT NULL,
    details TEXT
);

-- one row per port checked in a run
CREATE TABLE IF NOT EXISTS port_checks (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    audit_run_id BIGINT NOT NULL REFERENCES audit_runs(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    address TEXT NOT NULL,
    port INTEGER NOT NULL,
    is_listening BOOLEAN NOT NULL,
    http_status INTEGER,
    is_healthy BOOLEAN NOT NULL,
    error_message TEXT
);

CREATE TABLE IF NOT EXISTS backup_runs (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    backup_id TEXT NOT NULL UNIQUE,
    hostname TEXT NOT NULL,
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at TIMESTAMPTZ,
    status TEXT NOT NULL CHECK (status IN ('running', 'completed', 'failed')),
    backup_dir TEXT NOT NULL,
    total_bytes BIGINT,
    verification_result TEXT,
    error_message TEXT,
    pruned_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS restore_runs (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    backup_id TEXT NOT NULL,
    hostname TEXT NOT NULL,
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at TIMESTAMPTZ,
    status TEXT NOT NULL CHECK (status IN ('running', 'completed', 'failed'))
);

-- the dashboards always look up the latest runs and the checks of one run
CREATE INDEX IF NOT EXISTS idx_audit_runs_started_at ON audit_runs(started_at DESC);
CREATE INDEX IF NOT EXISTS idx_service_checks_run ON service_checks(audit_run_id);
CREATE INDEX IF NOT EXISTS idx_port_checks_run ON port_checks(audit_run_id);
