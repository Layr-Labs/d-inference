package registry

import (
	"time"
)

// SetReleasePolicyGeneration atomically publishes the active-release policy
// generation used by routing. Existing application evidence that stillApproved
// reports as valid under the NEW policy is carried forward at the new
// generation — a routine release registration must not deroute the whole fleet
// of healthy, still-approved providers for up to a challenge interval.
// Evidence not carried forward is removed synchronously.
//
// When the new policy is REQUIRED, the returned slice holds every connected
// provider that was NOT carried forward — including providers that held no
// evidence at all (e.g. the first activation of a required policy over a fleet
// that never needed evidence before). The caller must kick each one for an
// immediate re-challenge; otherwise the fleet idles unroutable until the
// periodic ticker, whose interval outlives the request queue. Carried-forward
// providers are never returned, so already-current providers get no duplicate
// kick. When the new policy is NOT required, nothing is returned: evidence is
// not a routing gate, so the periodic ticker is soon enough.
//
// A concurrently completing old challenge cannot install evidence at all:
// GrantApplicationEvidenceIfNotUntrusted refuses any grant whose generation is
// not current (atomically, under the same registry lock) and kicks that
// provider for an immediate re-challenge.
func (r *Registry) SetReleasePolicyGeneration(
	generation uint64, required bool,
	stillApproved func(ApplicationEvidence) bool,
) (needChallenge []string) {
	r.mu.Lock()
	r.releasePolicyGeneration = generation
	r.releasePolicyRequired = required
	enforced := r.releasePolicyEnforcedLocked()
	for id, provider := range r.providers {
		provider.mu.Lock()
		evidence := provider.ApplicationEvidence
		if evidence.EvidenceGeneration != 0 && stillApproved != nil && stillApproved(evidence) {
			provider.ApplicationEvidence.PolicyGeneration = generation
			provider.mu.Unlock()
			continue
		}
		provider.ApplicationEvidence = ApplicationEvidence{}
		// Capability invalidation is an ENFORCE-mode consequence: capabilities
		// gate capability-required catalog models, so clearing them in shadow
		// would let evidence bookkeeping remove real capacity — exactly what
		// shadow mode promises not to do. The re-challenge kicked below
		// re-reconciles capabilities within one challenge round-trip anyway.
		if enforced {
			provider.RuntimeCapabilities = nil
		}
		provider.mu.Unlock()
		if required {
			needChallenge = append(needChallenge, id)
		}
	}
	r.mu.Unlock()
	return needChallenge
}

// providerHoldsCurrentApplicationEvidenceLocked reports whether p holds
// generation-current application evidence bound to its live identity: current
// policy generation, this connection's process key, the current APNs token
// (tokenless providers pass with matching empty tokens; token possession is
// enforced only by the code-identity gate), the registered version/backend,
// and the registration-attested SE identity. Caller must hold r.mu; provider
// fields are read without p.mu, matching the routing chokepoint's semantics.
func (r *Registry) providerHoldsCurrentApplicationEvidenceLocked(p *Provider) bool {
	evidence := p.ApplicationEvidence
	return evidence.EvidenceGeneration != 0 &&
		evidence.PolicyGeneration == r.releasePolicyGeneration &&
		evidence.ProcessPublicKey == p.PublicKey &&
		evidence.APNsToken == p.APNsDeviceToken &&
		evidence.Version == p.Version &&
		evidence.Backend == p.Backend &&
		evidence.BinaryHash != "" &&
		p.AttestationResult != nil &&
		evidence.SEPublicKey == p.AttestationResult.PublicKey &&
		evidence.Serial == p.AttestationResult.SerialNumber
}

// SetReleasePolicyEnforcement switches the release-policy routing gate between
// SHADOW (false, default: evidence derived/granted/swept and counted but never
// blocks routing) and ENFORCE (true: the routing chokepoint requires current
// evidence once any configured enforce-after delay has passed). Thread-safe.
func (r *Registry) SetReleasePolicyEnforcement(enforced bool) {
	r.mu.Lock()
	r.releasePolicyEnforced = enforced
	r.mu.Unlock()
}

// SetReleasePolicyEnforceAfter defers enforcement until t (zero = immediate).
// Set at startup so a restart into enforce mode keeps routing like shadow
// until the reconnected fleet has completed its first challenge cycles and
// re-earned evidence. Thread-safe.
func (r *Registry) SetReleasePolicyEnforceAfter(t time.Time) {
	r.mu.Lock()
	r.releasePolicyEnforceAfter = t
	r.mu.Unlock()
}

// releasePolicyEnforcedLocked reports whether the evidence gate is LIVE right
// now: enforcement configured and past any enforce-after delay. Caller holds r.mu.
func (r *Registry) releasePolicyEnforcedLocked() bool {
	return r.releasePolicyEnforcedAtLocked(time.Now())
}

// releasePolicyEnforcedAtLocked is releasePolicyEnforcedLocked at an explicit
// instant (the fleet walks pass their captured clock). Caller holds r.mu.
func (r *Registry) releasePolicyEnforcedAtLocked(now time.Time) bool {
	return r.releasePolicyEnforced &&
		!now.Before(r.releasePolicyEnforceAfter)
}

// ReleasePolicyEnforced reports whether missing application evidence currently
// blocks routing. Thread-safe.
func (r *Registry) ReleasePolicyEnforced() bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.releasePolicyEnforcedLocked()
}
