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
// provider. A prediction exists only for an attempt routed to a credited
// holder. For every other attempt routing made none, and it is recorded as
// unknown rather than zero: the funnel's predicted-unknown count is "no
// prediction was made", not an observation gap.
func (pr *PendingRequest) CacheFunnelAttempt() cachefunnel.Attempt {
	if pr == nil {
		return cachefunnel.Attempt{}
	}
	attempt := cachefunnel.Attempt{
		Routing: cachefunnel.RoutingFromOpportunity(pr.CacheOpportunityReason()),
		Scoped:  pr.CacheRoutingParticipates(),
	}
	if pr.CacheSelectionSelected && pr.cacheSelectionPredictedTokens > 0 {
		attempt.Predicted = cachefunnel.KnownTokens(pr.cacheSelectionPredictedTokens)
	}
	return attempt
}
