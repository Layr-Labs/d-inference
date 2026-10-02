package registry

// providerAutopilotRoutingBlockedLocked is a capacity gate, not a catalog or
// trust gate. Managed providers retain their cached inventory for planning but
// accept network inference only on confirmed warm models, outside transitions.
// The provider applies the same rule, including owner requests over the network;
// direct local inference retains its independent admission/ownership checks.
// Caller holds r.mu and p.mu.
func providerAutopilotRoutingBlockedLocked(p *Provider, model string) bool {
	if !providerOrdinaryModelAllowedLocked(p, model) {
		return true
	}
	if providerAutopilotTransitionLocked(p) {
		return true
	}
	if !providerAutopilotManagedLocked(p) {
		return false
	}
	if p.BackendCapacity != nil {
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model == model {
				return !slotStateModelLoaded(slot.State)
			}
		}
	}
	return true
}

// Active control or an explicit pause owns residency. Accepted commands retain
// their fence until reconciliation. Consent without control keeps ordinary
// serving policy, and a hypothetical plan never claims mutation ownership.
func providerLegacyModelChangesBlockedLocked(p *Provider) bool {
	return providerAutopilotManagedLocked(p) || providerAutopilotTransitionLocked(p)
}
