package contracts

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
