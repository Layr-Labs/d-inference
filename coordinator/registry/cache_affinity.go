package registry

// cacheAffinityEligibleLocked requires the scan's registry lock and p.mu.
// Quarantine retains the advertised capability, so readiness alone is not
// sufficient. Follow the same registry -> provider -> tracker lock order as
// disablePrefixCacheV2Model, using the current capability to check its fence.
func (r *Registry) cacheAffinityEligibleLocked(p *Provider, model string, plan CachePlan) bool {
	tracker := r.cacheRouting
	if p.PrefixCacheProtocol < 2 || tracker == nil || plan.generation != tracker.generation ||
		tracker.generation.revoked.Load() {
		return false
	}
	now := tracker.now()
	for _, tier := range [...]string{"ssd", "memory"} {
		capability, ok := p.prefixCacheCapabilityLocked(model, tier)
		if ok && capabilityMatchesPlan(capability, plan) &&
			!tracker.capabilityRejected(p.ID, model, tier, capability, now) {
			return true
		}
	}
	return false
}
