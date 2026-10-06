package registry

import "time"

// PrivateText evaluates the private-text authorization chokepoint independently
// of model, capacity and public trust-floor eligibility.
func (e *ProviderEligibility) PrivateText(id string, now time.Time) bool {
	p := e.provider(id)
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return e.privateTextLocked(p, e.registry.releasePolicyEnforcedAtLocked(now), true, now)
}

func (e *ProviderEligibility) privateTextLocked(p *Provider, enforceEvidence, allowAppAttest bool, now time.Time) bool {
	r := e.registry
	if p.appAttestSecurityDenied {
		return false
	}
	appAttest := allowAppAttest && r.providerHasAppAttestAuthorizationLocked(p, now)
	if p.PublicKey == "" || !privateTextBackendSupported(p.Backend) || !p.EncryptedResponseChunks {
		return false
	}
	if !p.RuntimeManifestChecked {
		return false
	}
	// An App Attest lease carries independent SIP and code-identity evidence;
	// the legacy path requires coordinator-verified SIP, not a self-report.
	if !appAttest && !p.ChallengeVerifiedSIP {
		return false
	}
	if r.releasePolicyRequired &&
		enforceEvidence &&
		!appAttest &&
		!r.providerHoldsCurrentApplicationEvidenceLocked(p) {
		return false
	}
	if !appAttest && r.codeAttestationEnforcedAtLocked(now) && !p.CodeAttested {
		return false
	}
	caps := p.PrivacyCapabilities
	if caps == nil {
		return false
	}
	return caps.TextBackendInprocess &&
		caps.TextProxyDisabled &&
		caps.AntiDebugEnabled &&
		caps.CoreDumpsDisabled &&
		caps.EnvScrubbed
}
