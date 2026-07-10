-- Additive Rust coordinator schema (plan §12.1).
-- Applied by external migration tooling — never by application startup DDL.

CREATE SCHEMA IF NOT EXISTS rust_coord;

CREATE TABLE IF NOT EXISTS rust_coord.coordinator_ownership (
    id INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    fencing_epoch BIGINT NOT NULL DEFAULT 0,
    holder TEXT NOT NULL DEFAULT '',
    acquired_at TIMESTAMPTZ,
    heartbeat_at TIMESTAMPTZ,
    recovery_mode BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS rust_coord.inference_jobs (
    job_id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL,
    api_key_id TEXT NOT NULL DEFAULT '',
    public_model TEXT NOT NULL,
    concrete_model TEXT NOT NULL,
    state TEXT NOT NULL,
    reserved_total_micro_usd BIGINT NOT NULL DEFAULT 0,
    reserved_withdrawable_micro_usd BIGINT NOT NULL DEFAULT 0,
    request_digest TEXT NOT NULL DEFAULT '',
    coordinator_epoch BIGINT NOT NULL DEFAULT 0,
    job_version BIGINT NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    terminal_disposition TEXT,
    review_pending BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS rust_coord.inference_attempts (
    attempt_id TEXT PRIMARY KEY,
    job_id TEXT NOT NULL REFERENCES rust_coord.inference_jobs(job_id),
    provider_id TEXT NOT NULL DEFAULT '',
    session_epoch BIGINT NOT NULL DEFAULT 0,
    lease_id TEXT NOT NULL DEFAULT '',
    request_digest TEXT NOT NULL DEFAULT '',
    state TEXT NOT NULL,
    dispatch_nonce TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_rust_attempts_job
    ON rust_coord.inference_attempts(job_id);

CREATE TABLE IF NOT EXISTS rust_coord.provider_terminals (
    terminal_digest TEXT PRIMARY KEY,
    job_id TEXT NOT NULL,
    attempt_id TEXT NOT NULL,
    lease_id TEXT NOT NULL DEFAULT '',
    disposition TEXT NOT NULL,
    se_signature TEXT NOT NULL DEFAULT '',
    received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (attempt_id, terminal_digest)
);

CREATE TABLE IF NOT EXISTS rust_coord.financial_operations (
    operation_key TEXT PRIMARY KEY,
    job_id TEXT NOT NULL,
    op_type TEXT NOT NULL,
    amount_micro_usd BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS rust_coord.external_events (
    source TEXT NOT NULL,
    event_id TEXT NOT NULL,
    payload_digest TEXT NOT NULL DEFAULT '',
    processed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (source, event_id)
);

CREATE TABLE IF NOT EXISTS rust_coord.outbox (
    id BIGSERIAL PRIMARY KEY,
    kind TEXT NOT NULL,
    payload JSONB NOT NULL DEFAULT '{}',
    attempts INT NOT NULL DEFAULT 0,
    available_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
