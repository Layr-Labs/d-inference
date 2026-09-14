package attempt

import (
	"strings"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// RejectionKind refines a CAPACITY-class provider rejection by how the dispatch
// loop should respond. IsCapacityClassProviderError only answers the 5xx→429
// question; this answers the orthogonal "should we keep failing over?" question.
//
// A request that is intrinsically too large for the MODEL (its prompt exceeds
// the context window / per-batch prompt cap) is rejected identically by EVERY
// provider serving that model — so retrying across the fleet is pure waste. In
// prod this produced a 22-63× dispatch storm (ceiling maxDispatchAttempts=64),
// ~8.7 min latency per request, and 0% eventual success. Those stop after the
// first rejection. A provider/time-specific shortage (this node's live KV
// budget, a full queue, an update drain, a cold miss) MAY clear on another
// provider, so those still fail over — but under a tight cap so a fleet-wide
// transient can't storm either.
type RejectionKind int

const (
	// RejectionNotCapacity: a genuine fault (or unrecognised string) — the caller
	// keeps existing behavior (stays a 5xx fault, the per-provider breaker may
	// deroute the offender, and fault failover continues to maxDispatchAttempts).
	RejectionNotCapacity RejectionKind = iota
	// RejectionDeterministicUnservable: the request exceeds the model's context /
	// per-batch prompt limit — identical on every provider. Stop immediately and
	// return an uptime-neutral 429; retrying cannot help.
	RejectionDeterministicUnservable
	// RejectionTransientCapacity: a provider/time-specific shortage. Failover may
	// help, bounded by maxCapacityClassRetries.
	RejectionTransientCapacity
	// RejectionDeadlineUnreachable: this provider cannot produce first content
	// within the request's remaining absolute budget. Another provider may land,
	// so fail over without consuming the generic transient-capacity retry cap.
	RejectionDeadlineUnreachable
)

// ClassifyRejection refines a pre-content provider error into the dispatch
// response kind. reason is the structured InferenceErrorMessage.ErrorReason
// (may be empty); errStr is the human-readable provider error. providerBudget is
// the rejecting provider's most recently reported token budget for the model
// (ActiveTokenBudgetMax, 0 = unknown); modelContext is the model's context window
// (0 = unknown). A non-capacity error returns RejectionNotCapacity so callers
// preserve fault failover + the per-provider breaker. Matching mirrors
// IsCapacityClassProviderError (substring, case-insensitive,
// curly-apostrophe-normalised).
//
// providerBudget/modelContext exist to fix the unsound assumption that EVERY
// "batch token budget" rejection is fleet-wide deterministic. The provider's
// admission cap is min(context, activeTokenBudget) (BatchScheduler.swift
// resolvedMaxTokensPerBatch), and activeTokenBudget is memory-aware: under
// pressure it drops BELOW the context window. So the bare string can mean either
// "prompt > context" (deterministic — every provider rejects) or "prompt > THIS
// node's shrunk KV budget" (transient — a healthier provider serves). We treat it
// as deterministic UNLESS we have positive evidence of memory pressure on the
// rejecting provider (its reported budget is known and below the model context),
// in which case it is transient. An explicit "exceeds … context" phrasing names
// the context directly and is always deterministic.
//
// typedRejection is the wire CapacityRejectionReason from an enriched
// rejection ("" for legacy frames and funnels without one). A typed
// token_budget is AUTHORITATIVE transient for the batch-budget family: the
// provider's live gate named "the active-token budget cannot fit this request
// RIGHT NOW" (it frees as running sequences retire), so a deterministic-
// unservable verdict must never be re-derived from the stale heartbeat budget
// fallback — including when the enriched live budget is an explicit zero,
// which the heuristic below cannot tell apart from "unknown". This closes the
// residual stale-snapshot LIMITATION for enriched providers; legacy frames
// (no typed reason, heartbeat budget only) keep the heuristic unchanged.
func ClassifyRejection(reason, errStr string, providerBudget int64, modelContext int, typedRejection protocol.CapacityRejectionReason) RejectionKind {
	// P1 (structured provider reason): when a provider tells us EXACTLY why it
	// rejected, trust it instead of inferring deterministic-vs-transient from a
	// stale heartbeat snapshot. request_exceeds_context is fleet-wide deterministic
	// (every provider rejects → stop on attempt 1); request_exceeds_node / capacity
	// are this-node-specific (a bigger/idler box may serve → bounded failover). Old
	// providers send reason=="" and fall through to the string+budget heuristic.
	switch strings.ToLower(strings.TrimSpace(reason)) {
	case "request_exceeds_context":
		return RejectionDeterministicUnservable
	case "request_exceeds_node", "request_exceeds_node_budget", "capacity_busy":
		return RejectionTransientCapacity
	case ErrorReasonDraining:
		// Typed drain refusal (R2): this node is restarting; another serves.
		// Transient for failover, but shouldStopFailover does not charge it
		// against maxCapacityClassRetries (IsDrainingErrorReason).
		return RejectionTransientCapacity
	case ErrorReasonDeadlineUnreachable:
		return RejectionDeadlineUnreachable
	case "request_exceeds_batch_token_budget":
		return batchBudgetRejectionKind(typedRejection, providerBudget, modelContext)
	}
	// Capacity-class is gated by IsCapacityClassProviderError so fault strings
	// (checked first there) can never be miscategorised as a capacity shed.
	if !IsCapacityClassProviderError(errStr) && !IsCapacityClassProviderError(reason) {
		return RejectionNotCapacity
	}
	s := strings.ToLower(strings.TrimSpace(errStr + " " + reason))
	s = strings.ReplaceAll(s, "’", "'")
	// An explicit context-window/length overflow names the model context directly —
	// unambiguous, fleet-wide deterministic regardless of any provider's KV budget.
	// Match BOTH tenses ("exceeds"/"exceeded") and the bare "context length" /
	// "context window" markers (mirrored in capacityClassMarkers and the provider
	// breaker), so phrasings like "context length exceeded" / "context window
	// exceeded" / "prompt too long for context window" stop on the first provider
	// instead of failing over. Retrying cannot help.
	if strings.Contains(s, "context") &&
		(strings.Contains(s, "exceeds") || strings.Contains(s, "exceeded")) {
		return RejectionDeterministicUnservable
	}
	if strings.Contains(s, "context length") || strings.Contains(s, "context window") {
		return RejectionDeterministicUnservable
	}
	// "request exceeds batch token budget" (BatchSchedulerTypes:
	// requestExceedsBatchTokenBudget) is rejected at min(context, activeTokenBudget).
	// Deterministic ONLY when we can rule out that this node was memory-pressured:
	// a known reported budget below the model context means the binding term may
	// have been THIS node's KV budget, so a less-pressured provider could serve —
	// treat as transient (failover, capped). Otherwise (budget >= context, or
	// either value unknown) the binding term is the context, identical fleet-wide.
	if strings.Contains(s, "batch token budget") {
		return batchBudgetRejectionKind(typedRejection, providerBudget, modelContext)
	}
	// Everything else capacity-class is provider/time-specific — this node's live
	// KV budget ("exceeds active token budget" / "requires N tokens but only M
	// available" / "insufficient kv headroom"), a full queue, server busy, an
	// update drain, or a cold "not loaded" miss. Another provider (bigger budget,
	// free queue, already warm) may serve it, so fail over under the cap.
	return RejectionTransientCapacity
}

// batchBudgetRejectionKind resolves the "request exceeds batch token budget"
// family, shared by ClassifyRejection's reason-first and string paths. The
// admission cap is min(context, activeTokenBudget), so the rejection is
// deterministic only when the binding term was the fleet-wide CONTEXT:
//
//  1. A typed token_budget rejection is authoritative transient — the live
//     gate itself said the binding term was THIS node's budget, so the stale
//     heartbeat fallback must not overrule it (see ClassifyRejection's
//     typedRejection contract).
//  2. Absent a typed reason, positive evidence of memory pressure (a known
//     reported budget below a known model context) means a less-pressured
//     provider could serve — transient, capped failover.
//  3. Otherwise (budget >= context, or either value unknown) the binding term
//     is the context, identical fleet-wide — deterministic, stop at once.
func batchBudgetRejectionKind(typedRejection protocol.CapacityRejectionReason, providerBudget int64, modelContext int) RejectionKind {
	if typedRejection == protocol.RejectionReasonTokenBudget {
		return RejectionTransientCapacity
	}
	if modelContext > 0 && providerBudget > 0 && providerBudget < int64(modelContext) {
		return RejectionTransientCapacity
	}
	return RejectionDeterministicUnservable
}
