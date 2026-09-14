package registry

import (
	"time"
)

// providerSupportsPrivateTextLocked is the SINGLE routing chokepoint for
// private/text traffic. It is a method on *Registry (not a free function) so the
// APNs code-identity gate can consult the live rollout policy
// (codeAttestationEnforcedLocked) rather than a value stamped at registration —
// that is what lets the grace→enforce deadline flip without a reconnect. Callers
// hold r.mu (every call site is inside an r-locked Registry method).
func (r *Registry) providerSupportsPrivateTextLocked(p *Provider) bool {
	return r.providerSupportsPrivateTextAtLocked(p, time.Now())
}

// providerSupportsPrivateTextAtLocked is providerSupportsPrivateTextLocked
// evaluated at an explicit instant. The fleet walks capture one clock per
// walk and pass it here (via providerLivenessGateLocked) so the two rollout
// deadlines (release-policy enforce-after, APNs code-attestation) are not
// re-read from the wall clock once per eligible provider. Caller holds r.mu.
func (r *Registry) providerSupportsPrivateTextAtLocked(p *Provider, now time.Time) bool {
	return r.providerSupportsPrivateTextModeAtLocked(p, r.releasePolicyEnforcedAtLocked(now), now)
}

// providerSupportsPrivateTextModeLocked is the chokepoint body with the
// evidence gate explicit: enforceEvidence=false is the SHADOW/baseline surface
// (used live in shadow mode and by ApplicationEvidenceModelCoverage to compute
// the per-model flip criterion); enforceEvidence=true additionally requires
// generation-current application evidence. Caller holds r.mu.
func (r *Registry) providerSupportsPrivateTextModeLocked(p *Provider, enforceEvidence bool) bool {
	return r.providerSupportsPrivateTextModeAtLocked(p, enforceEvidence, time.Now())
}

// providerSupportsPrivateTextModeAtLocked is the chokepoint body at an explicit
// instant (see providerSupportsPrivateTextAtLocked). Caller holds r.mu.
func (r *Registry) providerSupportsPrivateTextModeAtLocked(p *Provider, enforceEvidence bool, now time.Time) bool {
	if p.PublicKey == "" || !privateTextBackendSupported(p.Backend) || !p.EncryptedResponseChunks {
		return false
	}
	if !p.RuntimeManifestChecked {
		return false
	}
	// Require coordinator-verified SIP (from attestation challenge) rather
	// than trusting the provider's self-reported SIPEnabled field.
	if !p.ChallengeVerifiedSIP {
		return false
	}
	// A configured release policy makes current active-release application
	// evidence mandatory independently of the APNs rollout deadline — but only
	// once enforcement is switched on AND past any enforce-after delay. In
	// shadow (the default) the predicate is still evaluated and counted
	// (ApplicationEvidenceModelCoverage, CountProvidersWithCurrentApplicationEvidence)
	// so operators prove coverage BEFORE anything can be derouted.
	if r.releasePolicyRequired &&
		enforceEvidence &&
		!r.providerHoldsCurrentApplicationEvidenceLocked(p) {
		return false
	}
	// APNs code-identity gate — the SINGLE chokepoint, no self-route exemption.
	if r.codeAttestationEnforcedAtLocked(now) && !p.CodeAttested {
		return false
	}
	caps := p.PrivacyCapabilities
	if caps == nil {
		return false
	}
	// Only mlx-swift is routable (enforced by privateTextBackendSupported above).
	// Python-specific caps (PythonRuntimeLocked, DangerousModulesBlocked) are
	// retained in the protocol struct for wire backward compat but are no longer
	// required for routing.
	return caps.TextBackendInprocess &&
		caps.TextProxyDisabled &&
		caps.AntiDebugEnabled &&
		caps.CoreDumpsDisabled &&
		caps.EnvScrubbed
}

func privateTextBackendSupported(backend string) bool {
	// Python/legacy inprocess-mlx backend is deprecated and no longer
	// routable. Only Swift (mlx-swift) providers are admitted.
	return backend == BackendMLXSwift
}

// SetCodeAttestationConfigured records whether an APNs code-identity attestor is
// wired. When configured the coordinator issues code-identity challenges; whether
// a passing challenge is REQUIRED for routing is governed separately by the
// enforcement deadline (SetCodeAttestationDeadline). Call during server setup.
func (r *Registry) SetCodeAttestationConfigured(v bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.codeAttestationConfigured = v
}

// SetCodeAttestationDeadline sets the instant at which code-identity attestation
// becomes MANDATORY for routing. A zero time means "grace/observe indefinitely"
// (challenge + measure, but keep routing un-attested providers). Safe to call at
// runtime; the gate re-reads it on every routing decision.
func (r *Registry) SetCodeAttestationDeadline(t time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.codeAttestationDeadline = t
}

// SetCodeAttestationPolicy sets both knobs atomically (used by tests).
func (r *Registry) SetCodeAttestationPolicy(configured bool, deadline time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.codeAttestationConfigured = configured
	r.codeAttestationDeadline = deadline
}

// CodeAttestationConfigured reports whether an APNs attestor is wired (so the
// connection handler should issue code-identity challenges). Thread-safe.
func (r *Registry) CodeAttestationConfigured() bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.codeAttestationConfigured
}

// CodeAttestationEnforced reports whether code-identity attestation is currently
// mandatory for routing (configured AND past the deadline). Thread-safe.
func (r *Registry) CodeAttestationEnforced() bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.codeAttestationEnforcedLocked()
}

// codeAttestationEnforcedLocked reports whether code-identity attestation is
// currently MANDATORY for routing. Caller must hold r.mu. Enforcement begins only
// when an attestor is configured AND a non-zero deadline has been reached; before
// then the fleet routes un-attested providers (grace window) while still being
// challenged.
func (r *Registry) codeAttestationEnforcedLocked() bool {
	return r.codeAttestationEnforcedAtLocked(time.Now())
}

// codeAttestationEnforcedAtLocked is codeAttestationEnforcedLocked at an
// explicit instant (the fleet walks pass their captured clock). Caller holds r.mu.
func (r *Registry) codeAttestationEnforcedAtLocked(now time.Time) bool {
	if !r.codeAttestationConfigured || r.codeAttestationDeadline.IsZero() {
		return false
	}
	return !now.Before(r.codeAttestationDeadline)
}
