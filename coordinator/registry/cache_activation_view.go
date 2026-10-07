package registry

import cacheactivation "github.com/eigeninference/d-inference/coordinator/internal/registry/cacheactivation"

func (r *Registry) CacheRoutingActivationStatus() cacheactivation.CacheRoutingActivationStatus {
	if r == nil {
		return cacheactivation.CacheRoutingActivationStatus{}
	}
	r.mu.RLock()
	gate := r.cacheActivation
	r.mu.RUnlock()
	return gate.Snapshot()
}
