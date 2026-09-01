package protocol

// Capacity probe/quote wire types — routing v2's honesty channel.
//
// Prod gap this answers (see registry/budget_clamp.go for the full account):
// 11,581 capacity-shaped provider 503s in 6h from boxes whose 5s heartbeats
// looked ~1.4% utilized. Heartbeat budgets are stale-OPTIMISTIC; the
// provider's live KV/admission gate is the only honest source. Rather than
// discovering that gate one bounced dispatch at a time, the coordinator asks:
// after the primary dispatches (probes run in parallel with the primary,
// never before it), the remaining shortlist candidates each get a
// capacity_probe and answer with a capacity_quote computed from the same
// lock-free snapshot their admission gate uses. Quotes confirm/demote backup
// candidates and time hedges; the coordinator's ledger remains the primary
// accounting — quotes are drift correction, not reservations.
//
// PRIVACY INVARIANT: a probe reaches providers that will likely NEVER serve
// the request, so it may carry bucketed request-shape metadata only. No
// prompt text, ciphertext, image bytes, tool bodies, consumer or account
// identity, and no stable request ID — QuoteID is random and request-local,
// so a probed-but-not-chosen provider can never correlate a probe with a
// request it later serves. TestCapacityProbeShapeClosed pins the field set.
//
// Mirrored in provider-swift/Sources/ProviderCore/Protocol/Types.swift; the
// Go and Swift encoders must agree on these JSON shapes byte-for-byte.

// CapacityRejectionReason is the closed, cross-language vocabulary for why a
// provider's live gate cannot admit a request of the probed shape. Shared by
// capacity_quote (RejectionReason when !AdmissibleNow) and the enriched
// inference_error fields, so the coordinator classifies both through one
// taxonomy. Unknown values are treated as absent (legacy heuristics apply);
// provider-authored prose never joins this contract.
type CapacityRejectionReason string

const (
	// RejectionReasonTokenBudget: the live active-token budget cannot fit
	// prompt bucket + max output tokens right now (transient: budget frees as
	// running sequences retire).
	RejectionReasonTokenBudget CapacityRejectionReason = "token_budget"
	// RejectionReasonKVHeadroom: the request can NEVER fit the slot's KV byte
	// budget, even into an empty batch — prompt bucket + max output exceeds
	// the whole grant (node-deterministic; a bigger box may serve).
	RejectionReasonKVHeadroom CapacityRejectionReason = "kv_headroom"
	// RejectionReasonMemoryCap: the unified-memory cap / activation reserve
	// blocks admission (e.g. would require an evicting cold load).
	RejectionReasonMemoryCap CapacityRejectionReason = "memory_cap"
	// RejectionReasonSlotState: the model slot is not in a servable state
	// (crashed, reloading, draining, shutting down, or the model is not
	// resident with no capacity report yet).
	RejectionReasonSlotState CapacityRejectionReason = "slot_state"
	// RejectionReasonTemplate: the slot cannot render this request shape's
	// chat template.
	RejectionReasonTemplate CapacityRejectionReason = "template"
	// RejectionReasonCapability: a required capability (e.g. vision, tool
	// constraints) is not available on this slot.
	RejectionReasonCapability CapacityRejectionReason = "capability"
	// RejectionReasonDeadline: admissible eventually, but not within the
	// probe's deadline_remaining_ms.
	RejectionReasonDeadline CapacityRejectionReason = "deadline"
)

// Valid reports whether r belongs to the protocol's closed vocabulary.
func (r CapacityRejectionReason) Valid() bool {
	switch r {
	case RejectionReasonTokenBudget,
		RejectionReasonKVHeadroom,
		RejectionReasonMemoryCap,
		RejectionReasonSlotState,
		RejectionReasonTemplate,
		RejectionReasonCapability,
		RejectionReasonDeadline:
		return true
	default:
		return false
	}
}

// CapacityQuoteConfidence grades the provenance of a quote's TTFT estimate.
const (
	// CapacityConfidenceHigh: quantiles come from a populated per-(model,
	// warm/cold, prompt-bucket, batch-bucket) ring of completed real requests.
	CapacityConfidenceHigh = "high"
	// CapacityConfidenceLow: the provider fell back to a coarser aggregate or
	// the benchmark manifest; the coordinator should trust its own floor.
	CapacityConfidenceLow = "low"
)

// CapacityProbePromptBucketTokens is the granularity probes round prompt
// estimates UP to. Bucketing (never exact counts) is what lets a probe reach
// non-serving providers: they learn request shape, not request content.
const CapacityProbePromptBucketTokens = 512

// CapacityProbeMessage (coordinator → provider) asks whether the provider
// could admit a request of this bucketed shape right now. Sent on the bounded
// data lane, never the strict control lane, so a probe storm cannot starve
// cancels or attestation. Providers answer from their published capacity
// snapshot — no actor hop, no inference, no allocation.
type CapacityProbeMessage struct {
	Type string `json:"type"`
	// QuoteID is a random, request-local correlation ID minted per probe. It
	// is deliberately NOT the public request ID (privacy invariant above).
	QuoteID string `json:"quote_id"`
	Model   string `json:"model"`
	// PromptTokensBucket is the coordinator's prompt-token estimate rounded UP
	// to a multiple of CapacityProbePromptBucketTokens.
	PromptTokensBucket int `json:"prompt_tokens_bucket"`
	MaxOutputTokens    int `json:"max_output_tokens"`
	// RequiresVision/VisionImageCount carry the vision shape when applicable;
	// both omitted for text-only requests so the legacy-shaped frame stays
	// minimal. Counts only — never image bytes or dimensions derived from
	// content.
	RequiresVision   bool `json:"requires_vision,omitempty"`
	VisionImageCount int  `json:"vision_image_count,omitempty"`
	// DeadlineRemainingMS is the time left on the request's absolute
	// first-content clock at probe send. A duration, never a wall-clock
	// timestamp: provider clocks skew.
	DeadlineRemainingMS int64 `json:"deadline_remaining_ms"`
}

// CapacityQuoteMessage (provider → coordinator) answers one probe.
//
// TTFT quantiles are END-TO-END distribution quantiles measured from
// completed real requests of comparable shape — never a sum of per-stage
// p95s, which compounds tail pessimism into a useless number. Durations only,
// never wall clocks. AdmissibleNow is advisory (the inference request itself
// is the reservation; the live gate re-decides on arrival): a stale-positive
// quote costs one enriched rejection, a stale-negative just demotes a backup.
type CapacityQuoteMessage struct {
	Type    string `json:"type"`
	QuoteID string `json:"quote_id"`
	// CapacitySeq names the capacity snapshot (BackendCapacity.CapacitySeq
	// stream) this quote was computed from. Carried so ordering against
	// heartbeats is possible; the coordinator currently trusts the probe
	// window (quotes expire in 250ms, far under a heartbeat interval) and
	// does not compare seqs.
	CapacitySeq   uint64 `json:"capacity_seq"`
	AdmissibleNow bool   `json:"admissible_now"`
	// RejectionReason is set exactly when !AdmissibleNow; an admissible quote
	// omits it.
	RejectionReason CapacityRejectionReason `json:"rejection_reason,omitempty"`
	TTFTP50MS       float64                 `json:"ttft_p50_ms"`
	TTFTP90MS       float64                 `json:"ttft_p90_ms"`
	// QueueEstMS is the provider's current queue-wait estimate for this shape,
	// already reflected in the TTFT quantiles' population but reported
	// separately so the coordinator's hedge timing can see queue pressure.
	QueueEstMS float64 `json:"queue_est_ms"`
	// AvailableTokenBudget is the live remaining token headroom of the gate
	// that would admit this request.
	AvailableTokenBudget int64 `json:"available_token_budget"`
	// Confidence is CapacityConfidenceHigh or CapacityConfidenceLow.
	Confidence string `json:"confidence"`
}
