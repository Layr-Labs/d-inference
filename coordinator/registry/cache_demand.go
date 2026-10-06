package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachedemand"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachehistory"
	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// Demand is advisory, never cache evidence. The retained component owns bounded
// keyed arrival history; this adapter binds it to authenticated routing plans.
type cacheDemandTracker struct {
	index   *cachehistory.Index
	history *cachedemand.Tracker
	limit   int
	ttl     time.Duration
}

func newCacheDemandTrackerWithDependencies(limit int, ttl time.Duration, deps CacheDependencies) *cacheDemandTracker {
	if deps.DemandLimit > 0 {
		limit = deps.DemandLimit
	}
	index := cachehistory.New()
	var history *cachedemand.Tracker
	if deps.Demand != nil {
		history = deps.Demand(limit, ttl, index)
	}
	if history == nil {
		history = cachedemand.New(limit, ttl, index)
	}
	return &cacheDemandTracker{index: index, history: history, limit: max(1, limit), ttl: ttl}
}

func (d *cacheDemandTracker) setOnTouched(fn func([]string, time.Time)) { d.history.SetOnTouched(fn) }
func (d *cacheDemandTracker) restore(records []crs.DemandRecord, now time.Time) []crs.DemandRecord {
	return d.history.Restore(records, now)
}
func (d *cacheDemandTracker) clear()                                    { d.history.Clear() }
func (d *cacheDemandTracker) stats() (entries int, capEvictions uint64) { return d.history.Stats() }

// observeCacheDemand reports whether the plan received FirstSightTokens.
func (t *cacheRoutingTracker) observeCacheDemand(plan *CachePlan, routeKey []byte, now time.Time) bool {
	if t == nil {
		return false
	}
	var history *cachedemand.Tracker
	if t.demand != nil {
		history = t.demand.history
	}
	return plan.ObserveRouteDemand(t.generation, history, routeKey, now, t.firstSightMinTokens)
}
