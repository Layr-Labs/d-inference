package registry

import "time"

// CanServeAlias evaluates the same constrained advertisement walk used by alias
// resolution. Structural probes exclude transient capacity and load cooldowns.
func (planner *ReservationPlanner) CanServeAlias(buildID string, allowedSerials map[string]struct{}, ownerAccountID string, selfRouteOnly, preferOwner bool, now time.Time, traits RequestTraits, structural bool) bool {
	r := planner.registry
	r.mu.RLock()
	defer r.mu.RUnlock()
	return planner.canServeAliasLocked(buildID, allowedSerials, ownerAccountID, selfRouteOnly, preferOwner, now, traits, structural)
}

func (planner *ReservationPlanner) canServeAliasLocked(buildID string, allowedSerials map[string]struct{}, ownerAccountID string, selfRouteOnly, preferOwner bool, now time.Time, traits RequestTraits, structural bool) bool {
	r := planner.registry
	// Copy candidate identities before taking any provider lock.
	for _, p := range r.providersForModelLocked(buildID) {
		p.mu.Lock()
		ok := func() bool {
			if len(allowedSerials) > 0 {
				serial := ""
				if p.AttestationResult != nil {
					serial = p.AttestationResult.SerialNumber
				}
				if _, in := allowedSerials[serial]; !in || serial == "" {
					return false
				}
			}
			owned := p.AccountID != "" && p.AccountID == ownerAccountID
			if selfRouteOnly && !owned {
				return false
			}
			minTrust := r.MinTrustLevel
			allowPrivate := false
			if owned && (selfRouteOnly || preferOwner) {
				minTrust = TrustNone
				allowPrivate = true
			}
			canRoute := r.providerCanRouteBuildLocked(p, buildID, minTrust, now, allowPrivate)
			if structural {
				canRoute = r.providerStructurallyCanRouteBuildLocked(p, buildID, minTrust, now, allowPrivate)
			}
			return canRoute && r.providerEligibleForTraitsLocked(p, buildID, traits)
		}()
		p.mu.Unlock()
		if ok {
			return true
		}
	}
	return false
}

// CanRouteBuild probes public build eligibility without imposing request-level
// headroom. The same indexed walk drives alias selection and rollout decisions.
func (planner *ReservationPlanner) CanRouteBuild(buildID string) bool {
	r := planner.registry
	r.mu.RLock()
	defer r.mu.RUnlock()
	return planner.canRouteBuildLocked(buildID)
}

func (planner *ReservationPlanner) canRouteBuildLocked(buildID string) bool {
	r := planner.registry
	now := time.Now()
	minTrust := r.MinTrustLevel
	for _, p := range r.providersForModelLocked(buildID) {
		p.mu.Lock()
		ok := r.providerCanRouteBuildLocked(p, buildID, minTrust, now, false)
		p.mu.Unlock()
		if ok {
			return true
		}
	}
	return false
}
