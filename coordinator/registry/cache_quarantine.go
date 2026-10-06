package registry

import "github.com/eigeninference/d-inference/coordinator/protocol"

type CacheQuarantiner interface{ Apply() }

// CacheQuarantine is a deferred, generation-bound effect. Its private plan is
// supplied only by a verified receipt decision, after releasing tracker.mu.
type CacheQuarantine struct {
	registry                  *Registry
	providerID, modelID, tier string
	provider                  *Provider
	tracker                   *cacheRoutingTracker
	expected                  protocol.PrefixCacheV2Capability
	plan                      CachePlan
	routeKey                  []byte
}

func (q CacheQuarantine) Apply() {
	r, provider, tracker := q.registry, q.provider, q.tracker
	// One r -> provider -> tracker transition also fences connection replacement.
	// These leaf mutations perform no I/O or callbacks into the registry.
	r.mu.RLock()
	defer r.mu.RUnlock()
	current := r.providers[q.providerID] == provider && r.cacheRouting == tracker
	if !current || provider == nil || tracker == nil {
		return
	}
	commit := CacheQuarantineCommit{quarantine: q}
	if r.cacheDependencies.QuarantineCommits != nil {
		r.cacheDependencies.QuarantineCommits(commit).Apply()
		return
	}
	commit.Apply()
}

// CacheQuarantineCommit applies one verified rejection while its caller retains
// registry ownership of the captured connection and generation.
type CacheQuarantineCommit struct{ quarantine CacheQuarantine }

func (commit CacheQuarantineCommit) Apply() {
	q := commit.quarantine
	provider, tracker := q.provider, q.tracker
	provider.mu.Lock()
	defer provider.mu.Unlock()
	capability, ok := provider.prefixCacheCapabilityLocked(q.modelID, q.tier)
	if !ok || capability != q.expected ||
		!tracker.rejectCapability(q.providerID, q.modelID, q.tier, capability, tracker.now()) {
		return
	}
	if q.plan.Present() && len(q.routeKey) > 0 {
		tracker.invalidateProviderPlan(q.providerID, q.plan, q.routeKey, cacheHolderRemovalProofMismatch)
	} else {
		tracker.invalidateProviderModel(q.providerID, q.modelID, cacheHolderRemovalProofMismatch)
	}
	provider.advanceCacheRevisionLocked()
}

// Quarantine consumes the result's private plan and publishes the actual effect
// through its optional producer. The ordinary path invokes the value directly.
func (q CacheQuarantine) Quarantine(plan CachePlan) {
	q.plan = plan
	if q.registry.cacheDependencies.Quarantines != nil {
		q.registry.cacheDependencies.Quarantines(q).Apply()
		return
	}
	q.Apply()
}
