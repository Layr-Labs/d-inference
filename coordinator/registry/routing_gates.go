package registry

import (
	"time"
)

// providerPassesRoutingGatesLocked is the single source of truth for the
// per-provider structural/privacy/cooldown/trait gates a request must clear
// before a provider is eligible to serve it. snapshotProviderIntoLockedEx (the
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
//   - capacity-reject cooldown (pair capacity-rejecting everything with ZERO
//     interleaved accepts — the black-hole signature)
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
	return r.providerPassesRoutingGatesLockedEx(p, model, traits, selfRouteOwner, now, false, false)
}

// providerPassesRoutingGatesLockedEx is providerPassesRoutingGatesLocked with
// two explicit switches. ignoreProviderBreaker skips ONLY the per-provider
// node-health breaker (and health ejection); it exists solely for the
// selectBestCandidateLockedFull fail-open fallback pass, so a fleet-wide fault
// rollout that trips the breaker on every provider can never deroute the
// entire fleet. ignoreCapacityCooldown skips ONLY the capacity-reject cooldown;
// it exists solely for the "would this pair otherwise pass?" re-check that
// lets the candidate scan and the QuickCapacityCheck preflight count a
// capacity-cooled pair as a TRANSIENT capacityRejection (429/queue material)
// instead of structural absence (a "no providers" 503) — it must never be set
// on an actual routing/admission decision. Every other caller goes through the
// default wrapper above (both always honored). Caller holds r.mu and p.mu.
func (r *Registry) providerPassesRoutingGatesLockedEx(p *Provider, model string, traits RequestTraits, selfRouteOwner bool, now time.Time, ignoreProviderBreaker, ignoreCapacityCooldown bool) bool {
	ok, _ := r.providerRoutingGateReasonLockedEx(p, model, traits, selfRouteOwner, now, ignoreProviderBreaker, ignoreCapacityCooldown)
	return ok
}

// providerRoutingGateReasonLockedEx is providerPassesRoutingGatesLockedEx
// returning the FIRST failing gate as a closed GateReason (meaningful only when
// ok is false; GateReasonCount when ok). It IS the gate — the boolean form is a
// wrapper — so the verdict and the reason can never drift. Allocation-free.
// Caller holds r.mu and p.mu.
func (r *Registry) providerRoutingGateReasonLockedEx(p *Provider, model string, traits RequestTraits, selfRouteOwner bool, now time.Time, ignoreProviderBreaker, ignoreCapacityCooldown bool) (bool, GateReason) {
	// Catalog membership + dedicated-box isolation: a request for a dedicated
	// model family (e.g. Gemma 4) may ONLY route to a provider whose ENTIRE
	// advertised catalog is that family. This single gate is shared by the
	// dispatch hot path and the OpenRouter capacity preflight, so the filter
	// restricts the routing candidate set AND the shed (429) decision together
	// with no drift. A caller self-routing to its OWN machine is exempt — owners
	// may run mixed boxes.
	if ok, reason := r.providerServesRoutableModelReasonLocked(p, model, selfRouteOwner); !ok {
		return false, reason
	}
	// The identity's fault-tracker gates (faultstate/state.go): cached on the
	// connected provider, so the five reads are atomic loads for a provider
	// with no fault state and one short gate.mu section per tracker that has
	// state — and confirmed against p.faultSession afterwards (gateView), so a rebind
	// landing mid-read cannot hand the scan an emptied gate.
	if !ignoreCapacityCooldown && providerDrainingLocked(p, now) {
		return false, GateCapacityCooldown
	}
	view := r.gateViewOf(p)
	if ok, reason := r.gateStateReasonLocked(&view, model, traits, now, ignoreProviderBreaker, ignoreCapacityCooldown); !ok {
		return false, reason
	}
	// Liveness/trust/privacy core. selfRouteOwner relaxes ONLY the hardware-trust
	// floor (to TrustNone) and private-only admission for a caller's own
	// (possibly un-enrolled) machine; every privacy-critical gate still applies.
	minTrust := r.MinTrustLevel
	if selfRouteOwner {
		minTrust = TrustNone
	}
	if ok, reason := r.providerLivenessGateReasonLocked(p, minTrust, selfRouteOwner, now); !ok {
		return false, reason
	}
	// Trait eligibility: a render-broken build is fenced for EVERY request shape
	// (a crashing chat template breaks plain text, tools, and multimodal alike),
	// while the capability version floors stay trait-scoped (tools-only today).
	if !r.providerEligibleForTraitsLocked(p, model, traits) {
		return false, GateTraitFloor
	}
	return true, GateReasonCount
}

// gateStateReasonLocked evaluates the five fault-tracker gates for the session
// behind view against its identity's gate and returns the first closed one
// (GateReasonCount when all pass), in the documented gate precedence. The
// verdict is confirmed against p.faultSession (gateView.moved) and re-read from the
// session's new gate when a rebind landed between the view's load and the
// reads — the scan, the commit's admit re-check and the preflight all come
// through here, so none of them can dispatch a session past a breaker or
// cooldown that moved with it. Caller holds p.mu (for the identity read).
func (r *Registry) gateStateReasonLocked(view *gateView, model string, traits RequestTraits, now time.Time, ignoreProviderBreaker, ignoreCapacityCooldown bool) (bool, GateReason) {
	nowNS := now.UnixNano()
	for {
		g := view.g
		reason := GateReasonCount
		switch {
		// Skip a provider-model pair cooling down after a dispatch-time load
		// failure ("insufficient memory") — it would instant-503 again, burning a
		// dispatch attempt.
		case g.DispatchLoadCooled(model, now):
			reason = GateDispatchLoadCooldown
		// Skip a triple quarantined by the inference-error circuit breaker for THIS
		// request shape: repeated provider-side (5xx) failures — e.g. a deterministic
		// chat-template render crash on tool schemas — mean a retry here fails
		// identically, so routing must fall to a different provider. Shape-keyed so a
		// tool failure does not deroute clean text traffic. Cleared by
		// RecordInferenceSuccess (same shape) or by TTL expiry.
		case g.InferenceErrorCooled(model, traits.CooldownShape(), now):
			reason = GateErrorCooldown
		// Skip a (provider, model) pair quarantined by the capacity-reject cooldown:
		// it kept capacity-rejecting with ZERO interleaved accepts (the black-hole
		// signature — e.g. a box whose engine misreports its token budget), so a
		// dispatch here is a guaranteed bounce while its idle-looking heartbeats
		// keep winning the cost scheduler. A busy box that is also SERVING never
		// trips this (any accept resets the streak), and the pair is re-probed once
		// its TTL expires. See faultstate/capacity_cooldown.go.
		case !ignoreCapacityCooldown && g.CapacityCooled(model, now):
			reason = GateCapacityCooldown
		// Skip a provider quarantined by the per-provider node-health breaker: a
		// node returning GENUINE-FAULT errors (500/502/504 or a
		// fault-shaped 503) for ~all of its requests is sick regardless of model or
		// shape, so it is derouted fleet-wide. This catches the node that fault-503s
		// every request — invisible to the shape-keyed inference-error breaker above
		// (which skips 503 as a capacity signal). Honored on the normal routing
		// path; the selectBestCandidateLockedFull fail-open pass sets
		// ignoreProviderBreaker so a bad fleet-wide rollout can't deroute everyone.
		case !ignoreProviderBreaker && g.BreakerOpenAt(nowNS):
			reason = GateBreaker
		// Skip a provider EJECTED by the stable-identity health breaker (faultstate/ejection.go):
		// a node whose serial/SE-key/account has collapsed to a near-total served-fault
		// rate is derouted even across reconnects (the session breaker above is wiped on
		// every disconnect, which the constantly-disconnecting zombies exploit). Same
		// fail-open contract: skipped on the ignoreProviderBreaker rescan, and an
		// un-attestable provider (empty stable id) is never ejected.
		case !ignoreProviderBreaker && healthEjectionEnabled() && r.ejectionOpenFor(g, stableProviderIdentityLocked(view.p), nowNS):
			reason = GateEjection
		}
		if !view.moved() {
			return reason == GateReasonCount, reason
		}
	}
}
