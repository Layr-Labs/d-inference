package protocol

import (
	"encoding/json"
)

// InferenceAcceptedMessage signals the provider accepted the request and is
// working on it (possibly reloading the backend). The coordinator extends the
// wait window to the full inference timeout, but can still retry if the
// provider fails before sending the first chunk.
type InferenceAcceptedMessage struct {
	Type      string `json:"type"`
	RequestID string `json:"request_id"`
}

// InferenceResponseChunkMessage carries a single SSE chunk from the provider.
// When E2E encryption is active, Data is empty and EncryptedData contains
// the encrypted chunk.
type InferenceResponseChunkMessage struct {
	Type          string            `json:"type"`
	RequestID     string            `json:"request_id"`
	Data          string            `json:"data,omitempty"`
	EncryptedData *EncryptedPayload `json:"encrypted_data,omitempty"`
}

// UsageInfo carries token usage information.
type UsageInfo struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
	// ReasoningTokens is the subset of CompletionTokens spent on
	// reasoning/analysis content (gpt-oss analysis channel, <think>
	// blocks, etc.), counted with the model tokenizer on the provider.
	// 0 when the response carried no reasoning content. Mirrors
	// `reasoningTokens` in the Swift UsageInfo. omitempty keeps the wire
	// shape unchanged for non-reasoning responses and older providers.
	ReasoningTokens    int     `json:"reasoning_tokens,omitempty"`
	CacheOutcome       string  `json:"cache_outcome,omitempty"`
	CacheTier          string  `json:"cache_tier,omitempty"`
	CachedTokens       int     `json:"cached_tokens,omitempty"`
	PrefillTokensSaved int     `json:"prefill_tokens_saved,omitempty"`
	CacheStageMs       float64 `json:"cache_stage_ms,omitempty"`
}

// InferenceCompleteMessage signals the provider finished generating.
type InferenceCompleteMessage struct {
	Type         string    `json:"type"`
	RequestID    string    `json:"request_id"`
	Usage        UsageInfo `json:"usage"`
	StopSequence string    `json:"stop_sequence,omitempty"` // Exact caller-authored stop string matched by the engine
	SESignature  string    `json:"se_signature,omitempty"`  // SE-signed response hash
	ResponseHash string    `json:"response_hash,omitempty"` // SHA-256 of response data
	// Profile is the optional provider request profile (system profiler).
	// Deliberately json.RawMessage, not a typed struct: the WS read loop only
	// length-checks it (≤ MaxInferenceProfileBytes) and retains the bytes; the
	// typed decode into InferenceProfile happens on the profile sink worker
	// after the terminal has been fully processed. A malformed profile can
	// therefore never fail the envelope decode of a terminal frame. Absent on
	// legacy providers. OBSERVABILITY ONLY: never routing, health, billing or
	// client output.
	Profile json.RawMessage `json:"profile,omitempty"`
}

// InferenceErrorMessage signals an error during inference.
type InferenceErrorMessage struct {
	Type        string               `json:"type"`
	RequestID   string               `json:"request_id"`
	Error       string               `json:"error"`
	StatusCode  int                  `json:"status_code"`
	ErrorReason string               `json:"error_reason,omitempty"`
	FailureCode InferenceFailureCode `json:"failure_code,omitempty"`
	// CoordinatorCause is set only on coordinator-synthetic channel messages.
	// json:"-" prevents a provider from supplying or observing it on the wire.
	CoordinatorCause CoordinatorInferenceErrorCause `json:"-"`
	// TerminalCause is the provider's typed terminal cause for this error
	// (closed vocabulary, mirrored by the Swift provider): admission_timeout,
	// prefill_stall, decode_stall, safety_deadline, backpressure_timeout,
	// watchdog, cancelled, engine_error. Optional: absent/empty means a legacy
	// provider and the coordinator applies its historical string/status
	// heuristics; an unknown value is treated as absent (plus a drift metric).
	// The coordinator classifies provider health from this cause
	// (api/terminal_cause.go) — platform-policy terminals (safety_deadline,
	// backpressure_timeout, cancelled) and capacity waits (admission_timeout)
	// must not strike health breakers.
	TerminalCause string `json:"terminal_cause,omitempty"`
	// AttemptUsage carries the engine-reconciled token usage of the failed
	// attempt at its terminal (partial generation included). Optional; legacy
	// providers omit it. OBSERVABILITY ONLY on the coordinator: it is persisted
	// on the route row and emitted in telemetry, but it never feeds billing,
	// refunds, reservations, provider earnings, or payouts.
	AttemptUsage *UsageInfo `json:"attempt_usage,omitempty"`

	// Enriched rejection (routing v2). A current provider that fast-rejects at
	// its live admission gate says WHY in machine-readable form, turning every
	// rejection into a fresh capacity sample for the coordinator's ledger,
	// budget clamp, and failure taxonomy — the gray-box incident
	// (registry/budget_clamp.go) was 11,581 opaque capacity 503s that had to
	// be re-learned one bounce at a time. All four fields are additive and
	// absent on legacy frames, so those decode byte-identically.
	//
	// RejectionReason is the bounded CapacityRejectionReason enum (shared with
	// capacity_quote). AvailableTokenBudget is the live gate's remaining token
	// headroom at rejection time — a POINTER because zero is a meaningful
	// measurement, not an unset default: a busy slot with exactly zero tokens
	// free must encode that zero (nil = legacy/unenriched, absent on the
	// wire), or the coordinator falls back to the stale heartbeat budget and
	// can misclassify a transient token_budget reject as fleet-deterministic
	// (codex P1-4). FeasibleAfterMS is the provider's busy-wait
	// forecast of when a request of this shape could next be admitted
	// (duration, never a wall clock) — emitted on busy-slot token_budget
	// rejections by quote-capable providers, from the same queue estimator
	// their capacity quotes use. CapacitySeq names the capacity snapshot the
	// gate decided from, letting the coordinator order the rejection against
	// heartbeats.
	RejectionReason      CapacityRejectionReason `json:"rejection_reason,omitempty"`
	AvailableTokenBudget *int64                  `json:"available_token_budget,omitempty"`
	FeasibleAfterMS      int64                   `json:"feasible_after_ms,omitempty"`
	CapacitySeq          uint64                  `json:"capacity_seq,omitempty"`
	// Profile is the optional provider request profile of the failed attempt.
	// Same contract as InferenceCompleteMessage.Profile: raw bytes on the
	// wire, length-checked on the read loop, decoded on the profile sink
	// worker. The sanitizer carries it through as an opaque byte copy so it
	// survives the confidentiality boundary without ever being read there.
	Profile json.RawMessage `json:"profile,omitempty"`
}

// ChatMessage is a single message in the OpenAI chat format.
type ChatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// InferenceRequestBody is the body sent inside an InferenceRequest.
type InferenceRequestBody struct {
	Model       string        `json:"model"`
	Messages    []ChatMessage `json:"messages"`
	Stream      bool          `json:"stream"`
	MaxTokens   *int          `json:"max_tokens,omitempty"`
	Temperature *float64      `json:"temperature,omitempty"`
	// Endpoint is the backend path to forward to (e.g. "/v1/chat/completions",
	// "/v1/completions", "/v1/messages"). Defaults to "/v1/chat/completions"
	// if empty, for backwards compatibility.
	Endpoint string `json:"endpoint,omitempty"`
}

// InferenceRequestMessage tells a provider to run inference.
// When E2E encryption is enabled, Body is empty and EncryptedBody contains
// the NaCl Box encrypted request. Only the provider's hardened process can
// decrypt it using its X25519 private key.
type InferenceRequestMessage struct {
	Type      string               `json:"type"`
	RequestID string               `json:"request_id"`
	Body      InferenceRequestBody `json:"body,omitempty"`
	// E2E encrypted request body (set when provider has a public key)
	EncryptedBody *EncryptedPayload `json:"encrypted_body,omitempty"`
	// FirstContentBudgetMS is the positive time remaining for this dispatch
	// attempt to produce its first content-bearing chunk. Zero preserves the
	// legacy wire shape by omitting the field.
	FirstContentBudgetMS int64  `json:"first_content_budget_ms,omitempty"`
	CacheReceiptNonce    string `json:"cache_receipt_nonce,omitempty"`
	CacheScope           string `json:"cache_scope,omitempty"`
	PrefixCacheProtocol  int    `json:"prefix_cache_protocol,omitempty"`
	// Echoed only for a negotiated checkpoint receipt attempt. An older
	// coordinator omits this, so new providers suppress checkpoint receipts.
	CacheReceiptBoundaryMode string `json:"cache_receipt_boundary_mode,omitempty"`
	// ToolSchemaMetadataProtocol authenticates coordinator-owned schema
	// metadata carried inside the encrypted body. Version 1 means the
	// coordinator rejected client-forged reserved keys before normalization.
	ToolSchemaMetadataProtocol int `json:"tool_schema_metadata_protocol,omitempty"`
}

// EncryptedPayload carries a NaCl Box encrypted message.
type EncryptedPayload struct {
	EphemeralPublicKey string `json:"ephemeral_public_key"` // sender's ephemeral X25519 public key (base64)
	Ciphertext         string `json:"ciphertext"`           // nonce || encrypted data (base64)
}

// CancelMessage tells a provider to cancel an in-flight request.
type CancelMessage struct {
	Type      string `json:"type"`
	RequestID string `json:"request_id"`
}
