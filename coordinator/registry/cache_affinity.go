package registry

type CacheAffinityEvaluator interface {
	EvaluateLocked(*Provider, string, CachePlan) bool
}

// CacheAffinityEvaluation binds affinity eligibility to one cache generation.
// EvaluateLocked requires the provider lock; the scheduler also retains its
// registry ownership while choosing and consuming the generation.
type CacheAffinityEvaluation struct{ tracker *cacheRoutingTracker }

// cacheAffinityEligibleLocked requires the scan's registry lock and p.mu.
// Quarantine retains the advertised capability, so readiness alone is not
// sufficient. Follow the same registry -> provider -> tracker lock order as
// CacheQuarantine, using the current capability to check its fence.
func (r *Registry) cacheAffinityEligibleLocked(p *Provider, model string, plan CachePlan) bool {
	tracker := r.cacheRouting
	if tracker == nil {
		return false
	}
	return tracker.affinity.EvaluateLocked(p, model, plan)
}

func (evaluation CacheAffinityEvaluation) EvaluateLocked(p *Provider, model string, plan CachePlan) bool {
	tracker := evaluation.tracker
	if p.PrefixCacheProtocol < 2 || tracker == nil || !plan.Authenticates(tracker.generation) || !tracker.generation.Active() {
		return false
	}
	now := tracker.now()
	for _, tier := range [...]string{"ssd", "memory"} {
		capability, ok := p.prefixCacheCapabilityLocked(model, tier)
		if ok && CapabilityMatchesPlan(capability, plan) &&
			!tracker.capabilityRejected(p.ID, model, tier, capability, now) {
			return true
		}
	}
	return false
}
