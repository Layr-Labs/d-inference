package registry

// denyAppAttestProviderLocked makes an App Attest security denial visible to
// both authorization checks and status-only availability/metrics readers.
// Caller holds r.mu and p.mu and has checked current registry membership.
// Registered providers contribute to the online/model counters until their
// first untrusted transition; subsequent denials and disconnect must not
// subtract them again. Keep the connected socket available for diagnostics.
func (r *Registry) denyAppAttestProviderLocked(p *Provider) {
	if p.Status != StatusUntrusted {
		r.onlineCount.Add(-1)
		for _, model := range p.Models {
			r.modelProviderDec(model.ID)
		}
		p.Status = StatusUntrusted
	}
	p.untrustedRecoverable = false
	p.appAttestSecurityDenied = true
	p.appAttestAuthorization = AppAttestServingAuthorization{}
	p.RuntimeCapabilities = nil
}
