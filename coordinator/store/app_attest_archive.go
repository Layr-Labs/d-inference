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

// AppAttestDiagnosticStore reads only provider lifecycle context, never proof
// bodies. It is optional: lookup failures must not affect proof acceptance.
type AppAttestDiagnosticStore interface {
	GetAppAttestAssertionDiagnostics(context.Context, string) (*AppAttestAssertionDiagnostics, error)
}

// Bound the key-index scan even when a key has a long history of failed proofs.
// No verified assertion in this window means the diagnostic baseline is unknown.
const AppAttestDiagnosticLookback = 100

// Keep members raw so a malformed optional timestamp cannot erase its valid peer.
type AppAttestAssertionDiagnostics struct {
	BootTime         json.RawMessage `json:"boot_time"`
	ProcessStartedAt json.RawMessage `json:"process_started_at"`
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
