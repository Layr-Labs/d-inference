package registry

import "github.com/eigeninference/d-inference/coordinator/internal/observation/cachefunnel"

// CacheRoutingCoversModel reports whether cache routing is on for a catalog
// model. It is the reuse funnel's population test and deliberately ignores
// everything a later stage decides (artifact allowlist, sampling, planning).
func (r *Registry) CacheRoutingCoversModel(model string) bool {
	if r == nil {
		return false
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	if r.cacheRoutingMode != CacheRoutingOn {
		return false
	}
	_, listed := r.modelCatalog[model]
	return listed
}

// CacheFunnelAttempt is this attempt's routing evidence for the reuse funnel.
// It is meaningful once the attempt has been reserved and prepared for a
// provider. The predicted token count is not carried here and stays unknown.
func (pr *PendingRequest) CacheFunnelAttempt() cachefunnel.Attempt {
	if pr == nil {
		return cachefunnel.Attempt{}
	}
	return cachefunnel.Attempt{
		Routing: cachefunnel.RoutingFromOpportunity(pr.CacheOpportunityReason()),
		Scoped:  pr.CacheRoutingParticipates(),
	}
}
