package registry

import "time"

// A model command may pass its catalog gate before a pair is selected. Debit a
// short-lived write obligation under the same registry/provider locks so the
// pair cannot slip into that gap; do not hold fleet locks across network IO.
// Planned load_model remains tracked by the existing pendingModelLoads ledger
// after its write. Local preparation must additionally stop autonomous model
// reconciliation before acknowledging the held canonical device gate.
func (r *Registry) beginVerifiedPairAwareModelCommand(p *Provider, canStartModelWork bool) (func(), error) {
	r.mu.RLock()
	if p == nil || r.providers[p.ID] != p {
		r.mu.RUnlock()
		return nil, ErrVerifiedPairStale
	}
	// Empty desired_models is a revoke, not new work; preserve its ordering and
	// delivery even during a pair hold. It cannot consume device capacity.
	if !canStartModelWork {
		r.mu.RUnlock()
		return func() {}, nil
	}
	p.mu.Lock()
	if !p.executionRolePermitsLocked(false) || r.providerPairHeldLocked(p, time.Now(), nil) {
		p.mu.Unlock()
		r.mu.RUnlock()
		return nil, ErrVerifiedPairBusy
	}
	p.pairModelCommandsInFlight++
	p.mu.Unlock()
	r.mu.RUnlock()
	return func() {
		p.mu.Lock()
		p.pairModelCommandsInFlight--
		p.mu.Unlock()
	}, nil
}

// Reject aliases already live at initial selection. Reserving one connection
// cannot establish quiescence for another connection on that physical device.
// Future aliases are excluded by the device indexes on every routing decision.
// Caller holds r.mu for writing and both selected member locks.
func (r *Registry) verifiedPairHasDuplicateConnectionLocked(members [2]*Provider, keys [2][]string) bool {
	for _, p := range r.providers {
		if p == members[0] || p == members[1] {
			continue
		}
		p.mu.Lock()
		observed := verifiedPairObservedDeviceKeysLocked(p)
		duplicate := verifiedPairKeysOverlap(observed, keys[0]) || verifiedPairKeysOverlap(observed, keys[1])
		p.mu.Unlock()
		if duplicate {
			return true
		}
	}
	return false
}
