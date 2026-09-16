package schema

const appAttestArchiveDDL = `
CREATE TABLE IF NOT EXISTS app_attest_evidence (
 id TEXT PRIMARY KEY, session_id TEXT NOT NULL, key_id TEXT NOT NULL, received_at TIMESTAMPTZ NOT NULL,
 action TEXT NOT NULL, sha256 TEXT NOT NULL, context JSONB NOT NULL,
 outcome TEXT NOT NULL DEFAULT 'pending', details JSONB NOT NULL DEFAULT '{}', completed_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS app_attest_evidence_session ON app_attest_evidence(session_id,received_at DESC);
CREATE INDEX IF NOT EXISTS app_attest_evidence_key ON app_attest_evidence(key_id,received_at DESC);
CREATE INDEX IF NOT EXISTS app_attest_evidence_time ON app_attest_evidence(received_at DESC);
CREATE INDEX IF NOT EXISTS app_attest_evidence_pending ON app_attest_evidence(received_at) WHERE outcome='pending';
CREATE TABLE IF NOT EXISTS app_attest_evidence_blobs (
 evidence_id TEXT PRIMARY KEY REFERENCES app_attest_evidence(id),
 proof_field TEXT NOT NULL, proof BYTEA NOT NULL
);
REVOKE ALL ON app_attest_evidence_blobs FROM PUBLIC;
`
