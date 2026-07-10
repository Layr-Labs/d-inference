-- Late terminal ingest + ACK payload (plan §4.6 / DECISIONS #21).
-- Additive only — never drops or rewrites existing rows.

ALTER TABLE rust_coord.provider_terminals
    ADD COLUMN IF NOT EXISTS ack_payload JSONB;

CREATE TABLE IF NOT EXISTS rust_coord.late_terminals (
    attempt_id TEXT NOT NULL,
    terminal_digest TEXT NOT NULL,
    job_id TEXT NOT NULL DEFAULT '',
    se_signature TEXT NOT NULL DEFAULT '',
    outcome TEXT NOT NULL DEFAULT '',
    seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (attempt_id, terminal_digest)
);

CREATE INDEX IF NOT EXISTS idx_rust_late_terminals_seen
    ON rust_coord.late_terminals(seen_at);
