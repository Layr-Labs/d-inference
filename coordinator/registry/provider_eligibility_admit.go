package registry

import "time"

// Admit revalidates current routing and capacity gates under the provider lock.
func (e *ProviderEligibility) Admit(id, model string, traits RequestTraits, selfRouteOwner, ignoreProviderBreaker bool, now time.Time) bool {
	p := e.provider(id)
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return e.admitLocked(p, model, traits, selfRouteOwner, ignoreProviderBreaker, now)
}

func (e *ProviderEligibility) admitLocked(p *Provider, model string, traits RequestTraits, selfRouteOwner, ignoreProviderBreaker bool, now time.Time) bool {
	r := e.registry
	if providerAutopilotRoutingBlockedLocked(p, model) {
		return false
	}
	if !r.providerPassesRoutingGatesLockedEx(p, model, traits, selfRouteOwner, now, ignoreProviderBreaker, false) {
		return false
	}
	// Apply the SAME quality-concurrency cap as the selection snapshot and the
	// preflight. This is the final admit re-check in ReserveProviderEx; if a
	// heartbeat bumped NumRunning after the snapshot was built, the legacy flat-cap
	// check here would let a box that just reached its quality cap be over-admitted.
	if !r.hasConcurrencyHeadroomForModelCapResolvedLocked(p, model) {
		return false
	}
	if p.BackendCapacity != nil {
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model != model {
				continue
			}
			switch slot.State {
			case "crashed", "reloading":
				return false
			}
			break
		}
	}
	return true
}
