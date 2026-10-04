package registry

import "github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"

func (r *Registry) newWarmLifecycle(session string) warmplan.LoadLifecycle {
	if r.warmLifecycleFactory != nil {
		return r.warmLifecycleFactory(session)
	}
	return new(warmplan.LoadState)
}

// Caller holds p.mu. The zero-value Provider uses the same concrete lifecycle as
// registered sessions, without exposing mutable timestamps to callers.
func (p *Provider) warmLifecycleLocked() warmplan.LoadLifecycle {
	if p.warmLoads == nil {
		p.warmLoads = new(warmplan.LoadState)
	}
	return p.warmLoads
}
