package registry

// RecordVerifiedAppAttestPresenter records no serving permission. The caller
// has cryptographically verified and durably archived a fresh assertion; this
// atomic binding check closes the race with replacement and local revocation.
func (r *Registry) RecordVerifiedAppAttestPresenter(p *Provider, credential, account, endpoint string) (current, revoked bool) {
	if p == nil || credential == "" || account == "" || endpoint == "" {
		return false, false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.providers[p.ID] != p {
		return false, false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.Status == StatusOffline || p.AccountID != account || p.PublicKey != endpoint {
		return false, false
	}
	p.appAttestPresenterID = credential
	_, revoked = r.appAttestRevokedCredentials[credential]
	if revoked {
		r.denyAppAttestProviderLocked(p)
	}
	return true, revoked
}

// VerifiedAppAttestPresenters includes presenter-only connections for the
// bounded revocation refresh. The result cannot grant a lease: it contains no
// proof, readiness, receipt or authorization timestamps.
func (r *Registry) VerifiedAppAttestPresenters() map[*Provider][]string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	result := make(map[*Provider][]string)
	for _, p := range r.providers {
		p.mu.Lock()
		if p.Status != StatusOffline && !p.appAttestSecurityDenied {
			keys := make([]string, 0, 2)
			if p.appAttestPresenterID != "" {
				keys = append(keys, p.appAttestPresenterID)
			}
			if p.appAttestCredentialID != "" && p.appAttestCredentialID != p.appAttestPresenterID {
				keys = append(keys, p.appAttestCredentialID)
			}
			if len(keys) > 0 {
				result[p] = keys
			}
		}
		p.mu.Unlock()
	}
	return result
}

// DenyAppAttestProvider fences a cryptographically verified presenter without
// accidentally denying a replacement connection that reused its registry ID.
func (r *Registry) DenyAppAttestProvider(p *Provider) bool {
	if p == nil {
		return false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.providers[p.ID] != p {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	r.denyAppAttestProviderLocked(p)
	return true
}
