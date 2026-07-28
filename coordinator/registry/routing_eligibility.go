package registry

import "time"

// routing_eligibility.go holds the composable primitives shared by every
// provider-eligibility decision. Five functions historically re-implemented
// overlapping subsets of these gates:
//
//   - providerPassesRoutingGatesLockedEx (scheduler.go) — dispatch hot path
//   - providerCanRouteBuildLocked        (registry.go)  — alias routability
//   - providerHasWarmModelLocked         (registry.go)  — warm detection
//   - publiclyRoutableLocked             (registry.go)  — public capacity feeds
//   - warmPoolCandidateReasonLocked      (warm_pool_controller.go) — warming
//
// (plus modelLoadCandidatePendingLocked, the load planner). They share two
// exactly-identical sub-pipelines — the liveness/trust/privacy core and the
// catalog+dedicated model gate — extracted here so the shared decision cannot
// drift. The function-specific gates (dispatch / inference-error cooldowns, the
// node-health breaker, trait eligibility, slot-state, hardware-fit, the
// warm-loaded check, and the warm pool's idle/thermal/free-for-load gates) stay
// in their respective callers because they are intentionally NOT shared. The
// warm-pool reason function additionally keeps its own copies because it emits
// granular per-gate reason labels (exposed in instrumentation) that a single
// boolean helper cannot preserve — see warmPoolCandidateReasonLocked.

// providerLivenessGateLocked checks the liveness/trust/privacy gates shared by
// every provider-eligibility decision, in this order:
//
//   - status is not offline/untrusted
//   - private-only admission (a private-only box is excluded unless allowPrivate)
//   - hardware-trust floor (TrustLevel >= minTrust)
//   - runtime verified
//   - private-text (E2E) support
//   - attestation-challenge freshness
//
// minTrust is the trust floor to enforce; allowPrivate admits an otherwise
// private-only machine. Callers relax BOTH (minTrust=TrustNone, allowPrivate=
// true) for a caller's own self-route to a personal (un-enrolled) Mac; every
// privacy-critical gate (runtime, private-text, challenge freshness) still
// applies, so plaintext is never exposed and only the genuinely-signed provider
// binary serves. This is exactly the set of gates publiclyRoutableLocked
// enforces. Caller holds r.mu and p.mu.
func (r *Registry) providerLivenessGateLocked(p *Provider, minTrust TrustLevel, allowPrivate bool, now time.Time) bool {
	if p.Status == StatusOffline || p.Status == StatusUntrusted {
		return false
	}
	if p.PrivateOnly && !allowPrivate {
		return false
	}
	if trustRank(p.TrustLevel) < trustRank(minTrust) {
		return false
	}
	// Dev-insecure skips the runtime-manifest and attestation-challenge liveness
	// gates (no signed runtime manifest is configured and challenge freshness is
	// irrelevant when attestation is disabled). The private-text (E2E) gate below
	// still runs — it is what keeps prompts encrypted — and the status/trust-floor
	// gates above are unchanged.
	if !r.DevInsecure && !p.RuntimeVerified {
		return false
	}
	if !r.providerSupportsPrivateTextLocked(p) {
		return false
	}
	if !r.DevInsecure &&
		(p.LastChallengeVerified.IsZero() || now.Sub(p.LastChallengeVerified) > challengeFreshnessMaxAge) {
		return false
	}
	return true
}

// providerServesRoutableModelLocked reports whether the provider advertises a
// catalog-allowed build of model AND is not excluded from it by the
// dedicated-box isolation rule. allowDedicated exempts the dedicated rule — the
// owner self-route context, where an owner may run a mixed box. That owner
// context also permits off-catalog models (still requiring an exact provider
// advertisement), but it does NOT lift the weight-hash gate on models the
// catalog tracks: the exemption widens WHICH models an owner may route to,
// not the tamper tripwire on catalog builds. Shared by the dispatch gate,
// alias routability, warm detection, and the load planner so the catalog +
// dedicated decision cannot drift across them. Caller holds r.mu and p.mu.
func (r *Registry) providerServesRoutableModelLocked(p *Provider, model string, allowDedicated bool) bool {
	var serves bool
	if allowDedicated {
		serves = r.providerServesOwnedRoutableModelLocked(p, model)
	} else {
		serves = r.providerServesCatalogModelLocked(p, model)
	}
	if !serves {
		return false
	}
	if !allowDedicated && r.providerExcludedByDedicatedRuleLocked(p, model) {
		return false
	}
	return true
}
