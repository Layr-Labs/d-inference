package registry

// BindVerifiedMachineIdentity accepts ONLY an inventory identity already bound
// by the API to the authenticated account and verified credential. A client
// UUID or serial is never an input. Canonical identity survives lease expiry so
// reconnects and renewals cannot reset fault history.
func (r *Registry) BindVerifiedMachineIdentity(p *Provider, accountID, machineID string) bool {
	if p == nil || accountID == "" || machineID == "" {
		return false
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	if r.providers[p.ID] != p {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.AccountID != accountID || p.Status == StatusOffline {
		return false
	}
	if p.verifiedMachineID != machineID || p.verifiedMachineAccount != accountID {
		p.appAttestAuthorization = AppAttestServingAuthorization{}
	}
	p.verifiedMachineID, p.verifiedMachineAccount = machineID, accountID
	r.bindStableFaultKey(p, stableProviderIdentityLocked(p))
	return true
}

func (p *Provider) GetVerifiedMachineIdentity() (accountID, machineID string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.VerifiedMachineIdentityLocked()
}

// VerifiedMachineIdentityLocked is for snapshot visitors already holding p.mu.
// These identifiers are for private aggregation, never public serialization.
func (p *Provider) VerifiedMachineIdentityLocked() (accountID, machineID string) {
	return p.verifiedMachineAccount, p.verifiedMachineID
}

// RequireVerifiedMachineIdentity must run before attaching registration
// evidence on an MDM-optional connection. A self-signed serial cannot become an
// operational identity even while fresh App Attest verification is pending.
func (p *Provider) RequireVerifiedMachineIdentity() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.requireVerifiedMachineIdentity = true
	if p.registry != nil {
		p.registry.bindStableFaultKey(p, stableProviderIdentityLocked(p))
	}
}
