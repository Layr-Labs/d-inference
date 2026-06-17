package registry

import "time"

// logRoutingDecision emits a structured debug-level record of the
// winning candidate and its cost breakdown. Cheap when the level is
// disabled, since slog short-circuits before formatting.
func (r *Registry) logRoutingDecision(model string, pr *PendingRequest, winner *routingCandidate, candidates int) {
	if r.logger == nil || winner == nil {
		return
	}
	bd := winner.breakdown
	r.logger.Debug("routing_decision",
		"request_id", pr.RequestID,
		"model", model,
		"winner", winner.provider.ID,
		"cost_ms", bd.Total,
		"state_ms", bd.StateMs,
		"queue_ms", bd.QueueMs,
		"pending_ms", bd.PendingMs,
		"backlog_ms", bd.BacklogMs,
		"this_req_ms", bd.ThisReqMs,
		"health_ms", bd.HealthMs,
		"effective_tps", winner.effectiveTPS,
		"effective_queue", winner.effectiveQueue,
		"candidates", candidates,
	)
}

// providerPassesRoutingGatesLocked is the single source of truth for the
// per-provider structural/privacy/cooldown/trait gates a request must clear
// before a provider is eligible to serve it. snapshotProviderLocked (the
// production dispatch hot path) and QuickCapacityCheck (the preflight) BOTH call
// it so the two can never drift — a prior bug had QuickCapacityCheck silently
// missing the dispatch-load cooldown, the inference-error cooldown, and the
// trait gates, so the preflight reported capacity that routing then refused.
//
// Gates, in evaluation order:
//   - catalog membership (advertises an allowed build of the model)
//   - dispatch-load cooldown (pair instant-503'd on "insufficient memory")
//   - inference-error cooldown, SHAPE-KEYED to traits.CooldownShape() (pair
//     returning repeated provider-side 5xx for THIS request shape)
//   - status not offline/untrusted
//   - private-only admission (only the owner's self-route may use it)
//   - hardware-trust floor (relaxed to TrustNone for the owner's own machine)
//   - runtime verified
//   - private-text support (E2E privacy backstop)
//   - challenge freshness
//   - trait eligibility: render-broken fences EVERY request shape; version
//     floors are trait-scoped (tools-only today)
//
// selfRouteOwner relaxes only the trust floor and private-only admission for a
// caller's own (possibly un-enrolled) machine; every privacy-critical gate
// still applies. Caller holds r.mu and p.mu.
func (r *Registry) providerPassesRoutingGatesLocked(p *Provider, model string, traits RequestTraits, selfRouteOwner bool, now time.Time) bool {
	if !r.providerServesCatalogModelLocked(p, model) {
		return false
	}
	// Skip a provider-model pair cooling down after a dispatch-time load
	// failure ("insufficient memory") — it would instant-503 again, burning a
	// dispatch attempt.
	if r.dispatchLoadCooldownActiveLocked(p.ID, model, now) {
		return false
	}
	// Skip a triple quarantined by the inference-error circuit breaker for THIS
	// request shape: repeated provider-side (5xx) failures — e.g. a deterministic
	// chat-template render crash on tool schemas — mean a retry here fails
	// identically, so routing must fall to a different provider. Shape-keyed so a
	// tool failure does not deroute clean text traffic. Cleared by
	// RecordInferenceSuccess (same shape) or by TTL expiry.
	if r.inferenceErrorCooldownActiveLocked(p.ID, model, traits.CooldownShape(), now) {
		return false
	}
	if p.Status == StatusOffline || p.Status == StatusUntrusted {
		return false
	}
	// A private-only machine never serves the public fleet — only its owner's
	// self-route requests.
	if p.PrivateOnly && !selfRouteOwner {
		return false
	}
	minTrust := r.MinTrustLevel
	if selfRouteOwner {
		minTrust = TrustNone
	}
	if trustRank(p.TrustLevel) < trustRank(minTrust) {
		return false
	}
	if !p.RuntimeVerified {
		return false
	}
	if !r.providerSupportsPrivateTextLocked(p) {
		return false
	}
	if p.LastChallengeVerified.IsZero() || now.Sub(p.LastChallengeVerified) > challengeFreshnessMaxAge {
		return false
	}
	// Trait eligibility: a render-broken build is fenced for EVERY request shape
	// (a crashing chat template breaks plain text, tools, and multimodal alike),
	// while the capability version floors stay trait-scoped (tools-only today).
	if !r.providerEligibleForTraitsLocked(p, model, traits) {
		return false
	}
	return true
}
