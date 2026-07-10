// Protocol v2 wire types (prepare / start / durable terminals).
//
// Dual-stack: v1 providers omit these fields and keep the existing
// inference_request / inference_accepted / inference_complete path.
// A provider advertises ProtocolCapabilities on register; the coordinator
// only sends v2 frames when the negotiated capability set supports them.
package protocol

import "encoding/json"

// Protocol v2 message type constants.
const (
	// Coordinator → Provider.
	TypePrepare = "prepare"
	TypeStart   = "start"
	TypeAbort   = "abort"
	// TypeCancel already exists in v1 and remains the post-start cancel.

	// Provider → Coordinator.
	TypePrepared         = "prepared"
	TypeStarted          = "started"
	TypeAborted          = "aborted"
	TypeCancelled        = "cancelled"
	TypeProviderTerminal = "provider_terminal"
	TypeTerminalAck      = "terminal_ack"
	TypeModelReady       = "model_ready"
	TypeModelGone        = "model_gone"
	TypeStructuredError  = "structured_error"
)

// ProtocolCapabilities is advertised at registration for capability negotiation.
// Semver floors are not used for v2 features.
type ProtocolCapabilities struct {
	ProtocolMajor        int   `json:"protocol_major"`
	ProtocolMinor        int   `json:"protocol_minor"`
	PreparedLeases       bool  `json:"prepared_leases,omitempty"`
	StartAuthorization   bool  `json:"start_authorization,omitempty"`
	StructuredErrors     bool  `json:"structured_errors,omitempty"`
	StartAck             bool  `json:"start_ack,omitempty"`
	AbortAck             bool  `json:"abort_ack,omitempty"`
	CancelAck            bool  `json:"cancel_ack,omitempty"`
	DurableTerminals     bool  `json:"durable_terminals,omitempty"`
	ModelLifecycleEvents bool  `json:"model_lifecycle_events,omitempty"`
	BinaryPayloadFrames  bool  `json:"binary_payload_frames,omitempty"`
	ProcessGeneration    int64 `json:"process_generation,omitempty"`
}

// SupportsV2 reports whether the provider can run the prepare/fund/start path.
func (c *ProtocolCapabilities) SupportsV2() bool {
	if c == nil {
		return false
	}
	return c.ProtocolMajor >= 2 &&
		c.PreparedLeases &&
		c.StartAuthorization &&
		c.DurableTerminals
}

// AttemptIdentity fences every v2 request frame.
type AttemptIdentity struct {
	JobID              string `json:"job_id"`
	AttemptID          string `json:"attempt_id"`
	LeaseID            string `json:"lease_id,omitempty"`
	SessionEpoch       uint64 `json:"session_epoch"`
	CoordinatorEpoch   uint64 `json:"coordinator_epoch"`
	DispatchNonce      string `json:"dispatch_nonce"`
	RequestDigest      string `json:"request_digest"`
	ProviderGeneration int64  `json:"provider_generation,omitempty"`
}

// PrepareMessage asks the provider to validate and reserve a non-generating lease.
type PrepareMessage struct {
	Type string `json:"type"`
	AttemptIdentity
	Model         string          `json:"model"`
	EncryptedBody string          `json:"encrypted_body,omitempty"`
	Body          json.RawMessage `json:"body,omitempty"`
}

// PreparedMessage returns exact resource/billing/execution facts for a lease.
type PreparedMessage struct {
	Type string `json:"type"`
	AttemptIdentity
	LeaseTTLMs         int64 `json:"lease_ttl_ms"`
	PromptTokens       int   `json:"prompt_tokens"`
	MaxOutputTokens    int   `json:"max_output_tokens"`
	EngineQueueDepth   int   `json:"engine_queue_depth"`
	PrefillCanBegin    bool  `json:"prefill_can_begin"`
	EstimatedPrefillMs int64 `json:"estimated_prefill_ms,omitempty"`
}

// StartMessage authorizes emission for a prepared lease (idempotent).
type StartMessage struct {
	Type string `json:"type"`
	AttemptIdentity
}

// StartedMessage acknowledges durable start authorization.
type StartedMessage struct {
	Type string `json:"type"`
	AttemptIdentity
}

// AbortMessage tombstones a not-yet-started lease (idempotent).
type AbortMessage struct {
	Type string `json:"type"`
	AttemptIdentity
	Reason string `json:"reason,omitempty"`
}

// AbortedMessage acknowledges abort.
type AbortedMessage struct {
	Type string `json:"type"`
	AttemptIdentity
}

// CancelledMessage acknowledges post-start cancellation (attempt is quiescent).
type CancelledMessage struct {
	Type string `json:"type"`
	AttemptIdentity
}

// StructuredErrorClass drives coordinator control flow (never human text).
type StructuredErrorClass string

const (
	ErrorClassInvalidRequest StructuredErrorClass = "invalid_request"
	ErrorClassCapacity       StructuredErrorClass = "capacity"
	ErrorClassModelNotReady  StructuredErrorClass = "model_not_ready"
	ErrorClassDraining       StructuredErrorClass = "draining"
	ErrorClassCancelled      StructuredErrorClass = "cancelled"
	ErrorClassFault          StructuredErrorClass = "fault"
	ErrorClassSecurity       StructuredErrorClass = "security"
)

// StructuredErrorMessage replaces substring classification for v2 providers.
type StructuredErrorMessage struct {
	Type string `json:"type"`
	AttemptIdentity
	Class   StructuredErrorClass `json:"class"`
	Message string               `json:"message,omitempty"`
}

// ProviderTerminalMessage is the canonical signed terminal for an attempt.
type ProviderTerminalMessage struct {
	Type string `json:"type"`
	AttemptIdentity
	Outcome               string               `json:"outcome"` // completed | cancelled | error
	ErrorClass            StructuredErrorClass `json:"error_class,omitempty"`
	PromptTokens          int                  `json:"prompt_tokens"`
	CompletionTokens      int                  `json:"completion_tokens"`
	ReasoningTokens       int                  `json:"reasoning_tokens,omitempty"`
	ResponseHash          string               `json:"response_hash"`
	FinalGenerated        int                  `json:"final_generated_tokens"`
	RollingHashCheckpoint string               `json:"rolling_hash_checkpoint,omitempty"`
	SESignature           string               `json:"se_signature"`
	TerminalDigest        string               `json:"terminal_digest"`
	Model                 string               `json:"model"`
	ProviderID            string               `json:"provider_id,omitempty"`
}

// TerminalAckMessage acknowledges durable receipt + financial disposition.
type TerminalAckMessage struct {
	Type string `json:"type"`
	AttemptIdentity
	TerminalDigest string `json:"terminal_digest"`
	Disposition    string `json:"disposition"` // settled | released | settled_reviewed | released_reviewed | late | conflict
}

// ModelReadyMessage / ModelGoneMessage are versioned lifecycle events.
type ModelReadyMessage struct {
	Type          string `json:"type"`
	Model         string `json:"model"`
	StateRevision int64  `json:"state_revision"`
	WeightHash    string `json:"weight_hash,omitempty"`
}

type ModelGoneMessage struct {
	Type          string `json:"type"`
	Model         string `json:"model"`
	StateRevision int64  `json:"state_revision"`
	Reason        string `json:"reason,omitempty"`
}

// BinaryPayloadHeaderLen is the fixed header size for v2 encrypted payload frames.
const BinaryPayloadHeaderLen = 64
