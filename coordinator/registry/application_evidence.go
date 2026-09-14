package registry

import (
	"time"
)

// ApplicationEvidence proves this connection's process runs an active approved
// release: the SE-signed challenge binary hash matched an active release row
// for the provider's version/platform/backend, and the runtime metallib hash
// matched that release. Deliberately NO python/runtime/per-family-template
// facts: mlx-swift providers never report them (python is gone; family
// template hashes were CI fabrications no provider could echo — requiring
// them made evidence underivable fleet-wide, 2026-08-31 incident).
type ApplicationEvidence struct {
	SEPublicKey      string
	Serial           string
	ProcessPublicKey string
	// APNsToken binds the evidence to the provider's APNs device token when it
	// has one. It MAY be empty: tokenless (legacy/headless) providers with a
	// valid signed challenge still earn application evidence — APNs token
	// possession is enforced exclusively by the APNs code-identity gate.
	APNsToken          string
	BinaryHash         string
	Version            string
	Platform           string
	Backend            string
	MetallibHash       string
	VerifiedAt         time.Time
	EvidenceGeneration uint64
	PolicyGeneration   uint64
}

// GrantApplicationEvidenceIfNotUntrusted stores the server-derived current
// release/runtime fact from a fresh signed process challenge. It deliberately
// does not set either code-attestation flag: self-measured hashes authenticate
// the claimant, not genuine Apple/APNs code identity.
//
// The evidence's policy generation is validated against the registry's live
// release-policy generation ATOMICALLY with the install (registry read-lock
// held across the provider-lock critical section, matching
// SetReleasePolicyGeneration's r.mu → p.mu order). This closes the
// clear/derive/grant race: a challenge that derived evidence from the OLD
// policy snapshot must not install it after a generation sweep — the sweep's
// kick (if any) may already have been consumed by an in-flight challenge, and
// non-required sweeps kick nobody, so the provider would otherwise idle
// un-kicked with stale-generation, unroutable evidence until the periodic
// ticker. A grant carrying a non-current generation is refused and the
// provider receives the same immediate out-of-band re-challenge kick a sweep
// invalidation triggers.
//
// An APNs device token is deliberately NOT required: tokenless
// (legacy/headless) providers with a valid signed challenge still earn
// application evidence. Token possession is enforced exclusively by the APNs
// code-identity gate; when the provider does hold a token, the evidence must
// still be bound to it.
func (p *Provider) GrantApplicationEvidenceIfNotUntrusted(evidence ApplicationEvidence) bool {
	r := p.registry
	if r != nil {
		r.mu.RLock()
	}
	staleGeneration := r != nil && evidence.PolicyGeneration != r.releasePolicyGeneration
	p.mu.Lock()
	if staleGeneration ||
		p.Status == StatusUntrusted ||
		evidence.SEPublicKey == "" || evidence.Serial == "" ||
		evidence.ProcessPublicKey == "" ||
		evidence.PolicyGeneration == 0 ||
		p.PublicKey != evidence.ProcessPublicKey ||
		p.APNsDeviceToken != evidence.APNsToken ||
		p.Version != evidence.Version ||
		p.Backend != evidence.Backend ||
		p.AttestationResult == nil || !p.AttestationResult.Valid ||
		p.AttestationResult.PublicKey != evidence.SEPublicKey ||
		p.AttestationResult.SerialNumber != evidence.Serial ||
		!p.RuntimeVerified || !p.RuntimeManifestChecked || !p.MetallibVerified {
		p.mu.Unlock()
		if r != nil {
			r.mu.RUnlock()
		}
		if staleGeneration {
			// Same recovery path as a sweep invalidation: re-verify now
			// instead of leaving the provider unroutable until the next tick.
			p.RequestImmediateChallenge()
		}
		return false
	}
	p.applicationEvidenceGeneration++
	evidence.EvidenceGeneration = p.applicationEvidenceGeneration
	p.ApplicationEvidence = evidence
	p.mu.Unlock()
	if r != nil {
		r.mu.RUnlock()
	}
	p.SignalApplicationProofSettled()
	p.reconcileRuntimeCapabilities()
	return true
}

func (p *Provider) ApplicationEvidenceSnapshot() (ApplicationEvidence, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	evidence := p.ApplicationEvidence
	return evidence, evidence.EvidenceGeneration != 0
}

func (p *Provider) ClearApplicationEvidence() {
	p.mu.Lock()
	p.ApplicationEvidence = ApplicationEvidence{}
	p.RuntimeCapabilities = nil
	p.mu.Unlock()
	p.reconcileRuntimeCapabilities()
}

func (p *Provider) SignalApplicationProofSettled() {
	if p.applicationProofSettled == nil {
		return
	}
	p.applicationProofOnce.Do(func() { close(p.applicationProofSettled) })
}

func (p *Provider) ApplicationProofSettledChan() <-chan struct{} {
	return p.applicationProofSettled
}
