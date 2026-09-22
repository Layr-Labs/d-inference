package registry

import "time"

// ProviderOwnerServingAuthorized reports the existing self/preferred-owner
// liveness/privacy policy. It is a diagnostic, not a public-fleet grant. Model
// compatibility and capacity still apply at actual dispatch.
func (r *Registry) ProviderOwnerServingAuthorized(p *Provider) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if p == nil || r.providers[p.ID] != p {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	now := time.Now()
	return p.AccountID != "" && !providerDrainingLocked(p, now) &&
		r.providerLivenessGateLocked(p, TrustNone, true, now)
}
