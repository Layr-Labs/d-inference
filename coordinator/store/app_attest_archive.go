package store

import (
	"context"
	"encoding/json"
	"time"
)

// Raw bytes live in a separate private table, never telemetry logs. PostgreSQL
// is the durable archive (including its normal backups); no volatile upload
// queue and no automatic purge. Accepted key/counter changes commit with results.
type AppAttestArchiveStore interface {
	BeginAppAttestEvidence(context.Context, AppAttestEvidence) error
	CompleteAppAttestEvidence(context.Context, string, AppAttestDecision) (string, error)
}

type AppAttestEvidence struct {
	ID         string
	SessionID  string
	KeyID      string
	ReceivedAt time.Time
	Action     string
	ProofField string // exact field retained even if base64 is malformed
	Proof      []byte
	SHA256     string
	Context    json.RawMessage // exact transcript inputs, verifier and policy version
}

type AppAttestDecision struct {
	Receipt *AppAttestReceipt
	Outcome string
	Details json.RawMessage
	Key     *AppAttestShadowKey
	Counter *uint32
	KeyID   string
	Owner   string
}

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
