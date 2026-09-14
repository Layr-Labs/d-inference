package attempt

import (
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Error feeds the circuit breakers for a provider-side error
// received on a pending request's ErrorCh (any phase, pre- or post-commit):
//   - the shape-keyed inference-error breaker (counts only sickness-shaped
//     500/502/504 for the (provider, model, shape) triple),
//   - the per-provider node-health breaker, which also counts fault-shaped
//     503s (errStr classifies capacity-503 vs fault-503),
//   - the stable-identity ejection breaker (survives reconnect churn), and
//   - the capacity-reject cooldown (the ONLY consumer of capacity-class
//     rejections, which every breaker above deliberately ignores).
//
// It emits the cool-down metric on the inference-error transition and the
// provider_breaker_open metric on the node-health transition into quarantine.
// errStr is the provider's error message and errReason its structured
// InferenceErrorMessage.ErrorReason ("" for synthetic timeouts and legacy
// providers) — the reason feeds the gray-box request-shape classification the
// same way the dispatch failover trusts it (ClassifyRejection P1).
// terminalCause is the provider's typed InferenceErrorMessage.TerminalCause
// ("" for synthetic terminals and legacy providers): a typed NEUTRAL cause
// (safety_deadline / backpressure_timeout / cancelled — platform policy or
// consumer behavior) feeds NOTHING here, strike or clear; a typed CAPACITY
// cause (admission_timeout — healthy but busy) feeds only the black-hole
// capacity cooldown. Absent/engine_error/unknown causes keep the legacy
// status/string funnels bit-for-bit (see inference/attempt/terminal_cause.go).
func (s Service) Error(providerID string, pr *registry.PendingRequest, statusCode int, errStr, errReason, terminalCause string, causes ...protocol.CoordinatorInferenceErrorCause) {
	if providerID == "" || pr == nil {
		return
	}
	// Structured health-neutral outcomes (IsProviderHealthNeutralErrorReason:
	// jinja_* template-render failures, tool_noncompliance, and the
	// request-clock-specific deadline_unreachable refusal) never feed provider
	// health or capacity trackers. Gating HERE (the single breaker chokepoint)
	// mirrors the dispatch-funnel gate
	// (dispatchState.noteProviderError) and the reputation exemption
	// (handleInferenceError), and closes the generic-inference path
	// (/v1/messages, /v1/completions), which calls Error directly on
	// pre-commit provider errors. Capacity-class rejections never carry these
	// reasons except deadline_unreachable, whose exclusion is intentional.
	if IsProviderHealthNeutralErrorReason(errReason) {
		return
	}
	// Typed drain refusal (R2, registry/drain_state.go): the provider is
	// restarting, not sick and not dishonest about capacity. It feeds NO
	// breaker and NO gray-box capacity state (no cooldown strike, no rate
	// derate, no budget clamp). Ingress marks draining before releasing the
	// pending slot, so its queue drain already skips this provider. Do not
	// repeat that mutation here: an idle/serving heartbeat may have cleared
	// the mark while this consumer was waiting to process its error channel.
	if IsDrainingErrorReason(errReason) {
		return
	}
	// Typed terminal-cause gate (the deadline-incident fix): the provider told
	// us WHY the attempt died, so the status/string heuristics below must not
	// misread a platform-policy terminal as sickness. Neutral causes touch no
	// tracker at all — strictly neutral, never a success/clear either.
	// admission_timeout records exactly one capacity-signal strike (the
	// black-hole cooldown, whose zero-interleaved-accepts discriminator keeps
	// serving boxes safe) and skips every fault breaker. All other causes —
	// absent (legacy/synthetic), engine_error, the fault causes
	// (prefill_stall / decode_stall / watchdog), and unknown drift values —
	// fall through to the unchanged legacy funnels.
	switch class, _ := ClassifyTerminalCause(terminalCause); class {
	case CauseClassNeutral:
		return
	case CauseClassCapacity:
		if s.deps.Registry().RecordCapacityRejectBusy(providerID, pr.Model) {
			s.deps.Metrics.Incr(MetricCapacityCooldownTripped, []string{"provider_id:" + providerID, "model:" + pr.Model})
			s.deps.Logger().Warn("capacity-reject cooldown tripped: provider+model admission-timing-out with zero interleaved accepts — routing will skip the pair until the cooldown expires",
				"provider_id", providerID,
				"model", pr.Model,
				"status_code", statusCode,
				"terminal_cause", terminalCause,
			)
		}
		return
	}
	// Late disconnect-flush strike (registry/version_reset.go): the session this
	// 502 was flushed from was dropped at or before its identity's version-
	// changed reset, so the reset already accounted for it. The flush is
	// recorded HERE, by the request goroutine, not by Disconnect — and
	// registration evicts a same-serial predecessor and stores the new version
	// on one goroutine, ahead of these consumers — so without the check the
	// new binary would be quarantined for the old one's death.
	if s.deps.Registry().IsSupersededDisconnectFlush(providerID, statusCode, causes...) {
		return
	}
	if s.deps.Registry().RecordInferenceError(providerID, pr.Model, statusCode, pr.Traits.CooldownShape(), causes...) {
		s.deps.Metrics.Incr("routing.cooldown_entered", []string{"model:" + pr.Model})
	}
	// Feed EVERY provider terminal into the per-provider node-health breaker (not
	// just the shape-keyed 5xx the inference-error breaker counts) so a node
	// fault-503ing ~all of its requests gets quarantined fleet-wide. errStr lets
	// the breaker tell a capacity-503 (ignored) from a fault-503 (counted). Both
	// breakers coexist.
	if opened, _ := s.deps.Registry().RecordProviderOutcome(providerID, false, statusCode, errStr, causes...); opened {
		s.deps.Metrics.Incr("routing.provider_breaker_open", []string{"model:" + pr.Model})
	}
	// Feed the STABLE-IDENTITY ejection breaker too (survives reconnect churn, so a
	// zombie that fault-loops while constantly disconnecting still accumulates).
	if ejected, _ := s.deps.Registry().RecordProviderSessionServeOutcome(providerID, false, statusCode, errStr, causes...); ejected {
		s.deps.Metrics.Incr("routing.provider_ejected", []string{"model:" + pr.Model})
	}
	// Feed the capacity-reject cooldown. Capacity-class rejections are
	// DELIBERATELY invisible to reputation and to ALL the breakers above (a
	// busy box must never be punished for shedding) — which turns a box that
	// capacity-rejects EVERYTHING into a routing black hole: its idle-looking
	// heartbeats keep winning the cost scheduler while every dispatch bounces
	// (2026-07 incident: 7 boxes, ~9k "token_budget_exhausted" rejections in
	// 30 min, zero successes). Strikes accumulate per (provider, model); any
	// accept (first content chunk or clean completion) resets the streak, so
	// transient fullness on a serving box can never trip. Gated to 429/404/5xx
	// so a client-shape 4xx that happens to carry a capacity-looking string
	// never strikes; explicit context-overflow rejections are excluded by
	// IsCapacityRejectStrike (they indict the request, not the provider).
	//
	// 404 is included WITH CARE for the cold "model not loaded" miss: a lazy
	// load on first touch makes a 404-then-load-then-serve sequence NORMAL
	// lifecycle, so the zero-interleaved-accepts discriminator remains the
	// safety — the first accept after the load clears the streak, and only a
	// box that 404s FOREVER (never loads, zero accepts) trips. A 404 whose
	// message is not capacity-class (e.g. "model not found" for an unknown
	// model id — a request-shape error) never strikes, because
	// IsCapacityRejectStrike only matches the capacity vocabulary
	// ("not loaded" / "no model loaded").
	if (statusCode == http.StatusTooManyRequests || statusCode == http.StatusNotFound ||
		statusCode >= http.StatusInternalServerError) &&
		IsCapacityRejectStrike(errStr) {
		// A cold "model not loaded" miss is benign warm-up lifecycle, not
		// capacity dishonesty. It still feeds the black-hole cooldown (a box
		// that 404s forever with zero accepts is a black hole), but it must NOT
		// derate the pair's gray-box capacity-503 RATE (capacity_rate.go) — that
		// window has no accept-reset, so counting a healthy box's normal reloads
		// would penalize it. A "batch token budget" reject that ClassifyRejection
		// proves REQUEST-deterministic (provider budget not below the model
		// context ⇒ the binding term was the fleet-wide context) indicts the
		// request, not the provider: it counts a cooldown strike only — arming
		// the one-shot clamp or the no-reset rate window off a single oversized
		// prompt would gate/derate a healthy pair. Genuine capacity/token-budget
		// 503s feed everything.
		var tripped bool
		switch {
		case IsColdModelMissRejection(errStr):
			tripped = s.deps.Registry().RecordCapacityRejectLifecycle(providerID, pr.Model)
		case s.isRequestShapeBatchBudgetReject(providerID, pr.Model, errStr, errReason):
			tripped = s.deps.Registry().RecordCapacityRejectRequestShape(providerID, pr.Model)
		default:
			tripped = s.deps.Registry().RecordCapacityReject(providerID, pr.Model)
		}
		if tripped {
			s.deps.Metrics.Incr(MetricCapacityCooldownTripped, []string{"provider_id:" + providerID, "model:" + pr.Model})
			s.deps.Logger().Warn("capacity-reject cooldown tripped: provider+model capacity-rejecting with zero interleaved accepts — routing will skip the pair until the cooldown expires",
				"provider_id", providerID,
				"model", pr.Model,
				"status_code", statusCode,
			)
		}
	}
}

// isRequestShapeBatchBudgetReject reports whether a capacity-class rejection
// is PROVEN request-deterministic by ClassifyRejection: a "batch token budget"
// reject from a provider whose reported token budget is not below the model's
// context window (the admission cap min(context, budget) was the CONTEXT — the
// prompt is too big fleet-wide), or an explicit request_exceeds_context
// structured reason. Such a reject must arm neither the one-shot budget clamp
// nor the no-reset capacity-503 rate window
// (RecordCapacityRejectRequestShape). When the reported budget IS below the
// context, the binding term may have been this node's memory-pressured KV
// budget — a genuine provider-specific capacity signal — and the reject feeds
// the full gray-box state (same discrimination the dispatch failover uses:
// ClassifyRejection in inference/attempt/rejection.go, DAR-347).
//
// Inputs mirror the dispatch path exactly: the structured errReason
// (InferenceErrorMessage.ErrorReason — a provider that says
// request_exceeds_node_budget / capacity_busy is TRUSTED over the stale
// heartbeat-budget heuristic, so a stale snapshot that still reads >= context
// cannot misroute a genuine node-capacity failure away from the gray-box
// trackers), providerBudget from the provider's last heartbeat
// (ReportedTokenBudgetMaxForModel), and modelContext from the model registry
// record. Called only inside the IsCapacityRejectStrike branch, so explicit
// context-overflow STRINGS never reach it (they never strike at all). The
// cheap gate keeps the two lookups off every other rejection.
func (s Service) isRequestShapeBatchBudgetReject(providerID, model, errStr, errReason string) bool {
	e := strings.ToLower(strings.TrimSpace(errStr))
	e = strings.ReplaceAll(e, "’", "'")
	reason := strings.ToLower(strings.TrimSpace(errReason))
	if !strings.Contains(e, "batch token budget") && reason != "request_exceeds_context" {
		return false
	}
	var providerBudget int64
	if p := s.deps.Registry().GetProvider(providerID); p != nil {
		providerBudget = p.ReportedTokenBudgetMaxForModel(model)
	}
	modelContext := 0
	if rec, err := s.deps.Store().GetModelRegistryRecord(model); err == nil && rec != nil {
		modelContext = rec.MaxContextLength
	}
	// No typed CapacityRejectionReason threads into the strike funnel
	// (Error carries only the string vocabulary), so this stays
	// the legacy string+heartbeat heuristic — enriched typed reasons already
	// reach it mapped onto error_reason by the sanitizer.
	return ClassifyRejection(errReason, errStr, providerBudget, modelContext, "") == RejectionDeterministicUnservable
}

// Success clears the inference-error strike state for the serving
// provider-model pair on a clean completion (streaming relay ended without a
// provider error; non-streaming response assembled OK).
func (s Service) Success(pr *registry.PendingRequest) {
	if pr == nil || pr.ProviderID == "" {
		return
	}
	s.deps.Registry().RecordInferenceSuccess(pr.ProviderID, pr.Model, pr.Traits.CooldownShape())
	// A clean completion is an ACCEPT for the capacity-reject cooldown: clear
	// the pair's reject streak, any active capacity cooldown, and the re-trip
	// backoff. Belt-and-braces with the commit-time accept (commitFirstContent)
	// and the only accept signal on paths that never stream content. For the
	// capacity-503 RATE window (capacity_rate.go) one served request must
	// count exactly ONE outcome, so this completion-time accept re-offers the
	// outcome only when the commit-time accept did not actually RECORD one
	// (RateOutcomeCountedSafe — stamped from RecordCapacityAccept's return at
	// every commit site). With rate tracking enabled, commit-time accepts are
	// retained even before the first reject; paths that never commit content
	// record their sole outcome here instead.
	s.deps.Registry().RecordCapacityAcceptOutcome(pr.ProviderID, pr.Model, !pr.RateOutcomeCountedSafe())
	// A clean completion proves the node is healthy — close its node-health
	// breaker (and reset the exponential backoff) if it had tripped.
	if _, closed := s.deps.Registry().RecordProviderOutcome(pr.ProviderID, true, 200, ""); closed {
		s.deps.Metrics.Incr("routing.provider_breaker_closed", []string{"model:" + pr.Model})
	}
	// A clean completion is a success for the stable-identity ejection breaker too
	// — closes it (half-open recovery) if this identity had been ejected.
	if sid := s.deps.Registry().GetProviderStableIdentity(pr.ProviderID); sid != "" {
		if _, recovered := s.deps.Registry().RecordProviderServeOutcome(sid, true, 200, ""); recovered {
			s.deps.Metrics.Incr("routing.provider_ejection_recovered", []string{"model:" + pr.Model})
		}
	}
}

// DispatchError records a provider error received while the
// dispatch loop had NOT yet committed to that provider: it feeds the
// inference-error breaker, refunds the failed attempt's provider-specific
// reservation top-up, and, when boilerplate chunks from that provider were
// being held (deferred commit), discards them and emits the pre-content
// failover counter — the invisible-retry signal that replaces what used to be
// an in-band SSE error after a premature commit. Returns true when held
// chunks were discarded so callers skip their generic retry counter.
//
// The refund lives here because both ErrorCh senders (handleInferenceError and
// registry.Disconnect's pending flush) remove the pending request BEFORE
// pushing the error, so the arm's Cancel sees RemovePending()==nil and
// skips its own refund — without this the custom-price surcharge reserved by
// settlement.Service.ReserveForProvider would be stranded for the failed attempt.
// settlement.Service.RefundProviderExtra is idempotent (it resets ReservedMicroUSD to the base),
// so arms where Cancel did refund are safe, and a failed pre-commit
// attempt never reaches settlement (its channels are closed and it is neither
// pending nor parked), so this can never double-credit against a settle.
func (s Service) DispatchError(provider *registry.Provider, pr *registry.PendingRequest, statusCode int, errStr, errReason, terminalCause string, held *[]string, causes ...protocol.CoordinatorInferenceErrorCause) (discardedHeld bool) {
	if provider != nil {
		s.Error(provider.ID, pr, statusCode, errStr, errReason, terminalCause, causes...)
	}
	s.deps.Reservations().RefundProviderExtra(pr)
	if held == nil || len(*held) == 0 {
		return false
	}
	*held = nil
	s.deps.Metrics.Incr("inference.dispatches", []string{"status:retry_precontent"})
	return true
}

// MetricCapacityCooldownTripped counts transitions of a (provider, model) pair
// into the capacity-reject routing cooldown (registry/capacity_cooldown.go),
// tagged provider_id + model. Distinct from routing.cooldown_entered (the 5xx
// inference-error breaker) and routing.provider_breaker_open (node health) so
// black-hole trips are independently alertable.
const MetricCapacityCooldownTripped = "routing.capacity_cooldown_tripped"
