package protocol

// InferenceFailureCode is the closed, cross-language vocabulary for failures
// returned by a provider while handling an inference request. Provider-authored
// prose is deliberately not part of this contract: the coordinator maps these
// values to fixed messages before logging, persistence, telemetry, or client
// delivery.
type InferenceFailureCode string

// CoordinatorInferenceErrorCause marks coordinator-synthetic terminals. It is
// never decoded from or encoded onto the provider wire, so an untrusted provider
// cannot claim these control-plane-only conditions.
type CoordinatorInferenceErrorCause string

const (
	// CoordinatorCauseProviderDisconnected marks the pending-request flush of
	// an ABRUPT socket loss (read error, OOM-suspected drop, stale eviction,
	// duplicate-serial kick): the provider vanished with work in flight, so
	// the flushed 502s strike the provider's stable-identity health trackers
	// (the reconnecting-zombie discriminator).
	CoordinatorCauseProviderDisconnected CoordinatorInferenceErrorCause = "provider_disconnected"
	// CoordinatorCauseProviderRestart marks the same flush when the provider
	// sent a peer-initiated graceful close (WebSocket 1000 normal / 1001
	// going-away — a stop, restart, or update). The requests still fail over
	// exactly like a disconnect, but the terminal is HEALTH-NEUTRAL: it
	// strikes no breaker, cooldown, or ejection window and clears none.
	CoordinatorCauseProviderRestart CoordinatorInferenceErrorCause = "provider_restart"
	// CoordinatorCauseDeadlineLateContent marks the coordinator's OWN
	// conversion of an ADMITTED attempt into a deadline_unreachable terminal:
	// the provider accepted the request and its first content (or clean
	// empty completion) reached the coordinator after the request-absolute
	// first-content deadline (api/provider.go). The wire shape is the same
	// capacity 503 the provider's projection refusal uses, so this marker is
	// the only thing that separates "the engine refused the budget" from
	// "the engine worked it and the clock ran out" — the deadline-wedge
	// tracker (registry/deadline_wedge.go) counts only the former.
	CoordinatorCauseDeadlineLateContent CoordinatorInferenceErrorCause = "deadline_late_content"
)

// InferenceErrorReasonProviderRestart is the coordinator-internal error_reason
// stamped on the flushed terminals of a graceful (peer-close) disconnect. It
// rides the existing error_reason funnel so every health tracker that already
// honors the health-neutral reason vocabulary treats the terminal as neutral
// without new plumbing. It is NEVER accepted from the provider wire: the
// ingress sanitizer maps every provider-supplied error_reason through a closed
// per-failure-code allowlist that does not include it.
const InferenceErrorReasonProviderRestart = "provider_restart"

// IsProviderDisconnect reports whether the cause marks a coordinator-synthetic
// disconnect flush of either flavor (abrupt or graceful restart) — the
// classification every "provider disconnected" presentation path keys on.
func (c CoordinatorInferenceErrorCause) IsProviderDisconnect() bool {
	return c == CoordinatorCauseProviderDisconnected || c == CoordinatorCauseProviderRestart
}

const (
	FailureCodeInvalidRequest    InferenceFailureCode = "invalid_request"
	FailureCodeInvalidMedia      InferenceFailureCode = "invalid_media"
	FailureCodeMediaTooLarge     InferenceFailureCode = "media_too_large"
	FailureCodeUnsupportedMedia  InferenceFailureCode = "unsupported_media"
	FailureCodeTemplateRender    InferenceFailureCode = "template_render"
	FailureCodeModelUnavailable  InferenceFailureCode = "model_unavailable"
	FailureCodeCapacity          InferenceFailureCode = "capacity"
	FailureCodeCancelled         InferenceFailureCode = "cancelled"
	FailureCodeEncryptionFailure InferenceFailureCode = "encryption_failure"
	FailureCodeGenerationFailure InferenceFailureCode = "generation_failure"
	FailureCodeInternalFailure   InferenceFailureCode = "internal_failure"
)

// Valid reports whether c belongs to the protocol's closed vocabulary.
func (c InferenceFailureCode) Valid() bool {
	switch c {
	case FailureCodeInvalidRequest,
		FailureCodeInvalidMedia,
		FailureCodeMediaTooLarge,
		FailureCodeUnsupportedMedia,
		FailureCodeTemplateRender,
		FailureCodeModelUnavailable,
		FailureCodeCapacity,
		FailureCodeCancelled,
		FailureCodeEncryptionFailure,
		FailureCodeGenerationFailure,
		FailureCodeInternalFailure:
		return true
	default:
		return false
	}
}
