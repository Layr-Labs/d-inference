package registry

import "time"

// ProviderLegacyServingDenialReason reports the first failed legacy serving
// prerequisite for an otherwise hardware-trusted connection. It is operator
// guidance only: dispatch still uses the independent authorization predicates.
// Self-signed App Attest candidates keep their App Attest reason instead.
func (r *Registry) ProviderLegacyServingDenialReason(p *Provider) string {
	if p == nil {
		return ""
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	if r.providers[p.ID] != p {
		return ""
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.TrustLevel != TrustHardware {
		return ""
	}
	now := time.Now()
	if r.providerLegacyServingAuthorizedLocked(p, now) {
		return ""
	}
	switch {
	case p.Status == StatusOffline || p.Status == StatusUntrusted || p.appAttestSecurityDenied:
		return "legacy_connection_unavailable"
	case providerStateRestoreRequiredLocked(p):
		return "legacy_state_restore_pending"
	case !r.trustMeetsMinimum(p.TrustLevel):
		return "legacy_trust_below_minimum"
	case !p.RuntimeVerified:
		return "legacy_runtime_unverified"
	case p.PublicKey == "" || !privateTextBackendSupported(p.Backend) || !p.EncryptedResponseChunks:
		return "legacy_private_transport_unavailable"
	case !p.RuntimeManifestChecked:
		return "legacy_runtime_manifest_unverified"
	case !p.ChallengeVerifiedSIP:
		return "legacy_sip_unverified"
	case r.releasePolicyRequired && r.releasePolicyEnforcedAtLocked(now) && !r.providerHoldsCurrentApplicationEvidenceLocked(p):
		return "legacy_release_evidence_missing"
	case r.codeAttestationEnforcedAtLocked(now) && !p.CodeAttested:
		return "legacy_code_identity_unverified"
	case !legacyPrivacyPostureComplete(p):
		return "legacy_privacy_posture_unverified"
	case p.LastChallengeVerified.IsZero() || now.Sub(p.LastChallengeVerified) > challengeFreshnessMaxAge:
		return "legacy_challenge_stale"
	default:
		// Keep diagnostics closed if a future authorization gate is added.
		return "legacy_serving_gate_unavailable"
	}
}

func legacyPrivacyPostureComplete(p *Provider) bool {
	c := p.PrivacyCapabilities
	return c != nil && c.TextBackendInprocess && c.TextProxyDisabled &&
		c.AntiDebugEnabled && c.CoreDumpsDisabled && c.EnvScrubbed
}
