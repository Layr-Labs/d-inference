package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func (r *Registry) newWarmHistory(session string) *warmplan.WorkHistory {
	if r.warmHistoryFactory != nil {
		return r.warmHistoryFactory(session)
	}
	return new(warmplan.WorkHistory)
}

// Caller holds p.mu after capacity sequence acceptance. Bare providers lazily
// acquire the same history component as registered sessions, under that lock.
func (p *Provider) reconcileWarmPoolWorkLocked(capacity *protocol.BackendCapacity, now time.Time, c *warmPoolController, eligible map[string]bool) {
	if p.warmWork == nil {
		p.warmWork = new(warmplan.WorkHistory)
	}
	if c == nil {
		p.warmWork.Reset()
		return
	}
	p.warmWork.Reconcile(capacity, now, c.state, eligible, firstContentPerformanceFreshness)
}
