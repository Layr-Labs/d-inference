package protocol

// DeadlineVerdict is the provider-observed engine submission result. Acceptance
// does not imply output: Continuation records immediate expiry/cancellation.
type DeadlineVerdict string

const (
	DeadlineVerdictAccepted            DeadlineVerdict = "accepted"
	DeadlineVerdictUnreachable         DeadlineVerdict = "deadline_unreachable"
	DeadlineVerdictExpiredBeforeSubmit DeadlineVerdict = "expired_before_submit"
	// Cancelled means the call did not return a verdict. It cannot prove
	// whether the engine briefly accepted the request before cancellation.
	DeadlineVerdictCancelled DeadlineVerdict = "cancelled"
	DeadlineVerdictOther     DeadlineVerdict = EnumOther
)

func (v DeadlineVerdict) Valid() bool {
	switch v {
	case DeadlineVerdictAccepted, DeadlineVerdictUnreachable, DeadlineVerdictExpiredBeforeSubmit,
		DeadlineVerdictCancelled, DeadlineVerdictOther:
		return true
	}
	return false
}

func (v DeadlineVerdict) Fold() DeadlineVerdict { return foldEnum(v, DeadlineVerdictOther) }

// DeadlineContinuation is an immediate check after receiving the result;
// absence means no exceptional continuation was recorded, not final success.
type DeadlineContinuation string

const (
	DeadlineContinuationExpired   DeadlineContinuation = "expired"
	DeadlineContinuationCancelled DeadlineContinuation = "cancelled"
	DeadlineContinuationOther     DeadlineContinuation = EnumOther
)

func (v DeadlineContinuation) Valid() bool {
	switch v {
	case DeadlineContinuationExpired, DeadlineContinuationCancelled, DeadlineContinuationOther:
		return true
	}
	return false
}

func (v DeadlineContinuation) Fold() DeadlineContinuation {
	return foldEnum(v, DeadlineContinuationOther)
}

// DeadlineProjection distinguishes a finite engine prediction from an unbounded
// result or a provider policy that did not request a prediction.
type DeadlineProjection string

const (
	DeadlineProjectionBounded      DeadlineProjection = "bounded"
	DeadlineProjectionUnbounded    DeadlineProjection = "unbounded"
	DeadlineProjectionNotAttempted DeadlineProjection = "not_attempted"
	DeadlineProjectionOther        DeadlineProjection = EnumOther
)

func (v DeadlineProjection) Valid() bool {
	switch v {
	case DeadlineProjectionBounded, DeadlineProjectionUnbounded, DeadlineProjectionNotAttempted,
		DeadlineProjectionOther:
		return true
	}
	return false
}

func (v DeadlineProjection) Fold() DeadlineProjection { return foldEnum(v, DeadlineProjectionOther) }

// DeadlineProjectionReason describes why projection was not attempted. The
// engine currently supplies no reason for an unbounded prediction.
type DeadlineProjectionReason string

const (
	DeadlineProjectionNoDeadline           DeadlineProjectionReason = "no_deadline"
	DeadlineProjectionModeOff              DeadlineProjectionReason = "mode_off"
	DeadlineProjectionUnsupportedScheduler DeadlineProjectionReason = "unsupported_scheduler"
	DeadlineProjectionMultimodal           DeadlineProjectionReason = "multimodal"
	DeadlineProjectionUnmeasuredPrefill    DeadlineProjectionReason = "unmeasured_prefill"
	DeadlineProjectionReasonOther          DeadlineProjectionReason = EnumOther
)

func (v DeadlineProjectionReason) Valid() bool {
	switch v {
	case DeadlineProjectionNoDeadline, DeadlineProjectionModeOff, DeadlineProjectionUnsupportedScheduler,
		DeadlineProjectionMultimodal, DeadlineProjectionUnmeasuredPrefill, DeadlineProjectionReasonOther:
		return true
	}
	return false
}

func (v DeadlineProjectionReason) Fold() DeadlineProjectionReason {
	return foldEnum(v, DeadlineProjectionReasonOther)
}

// DeadlineDecision is optional schema-1 diagnostic data, never an input to
// routing or billing. ObservedUS uses the provider profile's suspending-clock
// anchor; RemainingUS is measured on the continuous clock at that observation,
// NOT at the engine's atomic decision. SubmitRemainingUS is measured before
// submission. TPS fields are the effective inputs after any provider haircut.
// Missing numeric values remain unknown, including work for unbounded results.
type DeadlineDecision struct {
	Verdict                DeadlineVerdict          `json:"verdict,omitempty"`
	Continuation           DeadlineContinuation     `json:"continuation,omitempty"`
	Projection             DeadlineProjection       `json:"projection,omitempty"`
	ProjectionReason       DeadlineProjectionReason `json:"projection_reason,omitempty"`
	ObservedUS             *int64                   `json:"observed_us,omitempty"`
	RemainingUS            *int64                   `json:"remaining_us,omitempty"`
	SubmitRemainingUS      *int64                   `json:"submit_remaining_us,omitempty"`
	ProjectedServiceUS     *int64                   `json:"projected_service_us,omitempty"`
	ProjectedPrefillTokens *int                     `json:"projected_prefill_tokens,omitempty"`
	ProjectedDecodeTokens  *int                     `json:"projected_decode_tokens,omitempty"`
	PrefillTPS             *float64                 `json:"prefill_tps,omitempty"`
	DecodeTPS              *float64                 `json:"decode_tps,omitempty"`
}
