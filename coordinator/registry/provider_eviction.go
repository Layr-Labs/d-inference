package registry

import (
	"context"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

// StartEvictionLoop starts a background goroutine that removes providers
// that haven't sent a heartbeat within the given timeout. It stops when
// the context is cancelled.
func (r *Registry) StartEvictionLoop(ctx context.Context, timeout time.Duration) {
	ticker := time.NewTicker(timeout / 3)
	saferun.Go(r.logger, "registry.evictionLoop", func() {
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				r.evictStale(timeout)
			}
		}
	})
}

func (r *Registry) evictStale(timeout time.Duration) {
	now := time.Now()

	// Scan under the READ lock: the walk only reads LastHeartbeat (under p.mu)
	// and the previous sweep's strikes. evictStrikes is written solely by this
	// function on the single eviction goroutine, so a read-scan followed by a
	// short write-locked install is race-free — and the routing scans that
	// share r.mu are no longer blocked for a whole fleet walk every timeout/3.
	// Collect every provider's heartbeat age for the summary, and decide who to
	// evict: a provider is reaped only after it is stale on TWO consecutive
	// sweeps (strike >= 2), so a single transient stall that ages many
	// timestamps at once gives the fleet a sweep to recover instead of a mass
	// reap.
	r.mu.RLock()
	fleet := len(r.providers)
	ages := make([]time.Duration, 0, fleet)
	var nextStrikes map[string]int // allocated lazily: steady state carries nothing
	var toEvict []*Provider
	var evictAges []time.Duration
	for id, p := range r.providers {
		p.mu.Lock()
		lastHeartbeat := p.LastHeartbeat
		p.mu.Unlock()
		age := now.Sub(lastHeartbeat)
		ages = append(ages, age)
		if age > timeout {
			strikes := r.evictStrikes[id] + 1
			if strikes >= evictStrikeThreshold {
				toEvict = append(toEvict, p)
				evictAges = append(evictAges, age)
			} else {
				if nextStrikes == nil {
					nextStrikes = make(map[string]int)
				}
				nextStrikes[id] = strikes // carry the strike to next sweep
			}
		}
	}
	hadStrikes := len(r.evictStrikes) > 0
	r.mu.RUnlock()

	// Install the rebuilt strike map under the write lock only when it changes
	// anything (a strike carried or cleared). The steady state — nobody stale,
	// nothing carried — never takes the write lock at all.
	if hadStrikes || len(nextStrikes) > 0 {
		if nextStrikes == nil {
			nextStrikes = make(map[string]int)
		}
		r.mu.Lock()
		r.evictStrikes = nextStrikes
		r.mu.Unlock()
	}

	if len(ages) > 0 {
		amin, amed, ap90, amax := durationStats(ages)
		// A tight evicted-age spread (emax-emin small) means many providers went
		// stale at the same instant — a coordinator-side stall. A broad spread
		// means independent provider sleeps. The summary makes that diagnosable.
		emin, _, _, emax := durationStats(evictAges)
		r.logger.Info("eviction sweep",
			"fleet", fleet,
			"evicting", len(toEvict),
			"hb_age_min_s", int(amin.Seconds()),
			"hb_age_p50_s", int(amed.Seconds()),
			"hb_age_p90_s", int(ap90.Seconds()),
			"hb_age_max_s", int(amax.Seconds()),
			"evicted_age_min_s", int(emin.Seconds()),
			"evicted_age_max_s", int(emax.Seconds()),
		)
	}

	for _, p := range toEvict {
		// A heartbeat may recover this session after the read scan, or the
		// same id may name a replacement. Revalidate inside the removal lock.
		if r.disconnectProvider(p.ID, p, timeout, protocol.CoordinatorCauseProviderDisconnected) {
			r.logger.Warn("evicted stale provider", "provider_id", p.ID, "timeout", timeout)
		}
	}

	// Bound the per-identity gate index on the same cadence (faultstate/state.go):
	// prunes dead per-model entries and drops gates no live session references
	// once idle. Off the request path and outside r.mu.
	r.sweepGates(now)
}

// evictStrikeThreshold is how many consecutive stale sweeps trigger eviction.
// With a timeout/3 sweep cadence, 2 strikes ≈ one extra sweep interval of grace.
const evictStrikeThreshold = 2

// durationStats returns min, median, p90, max of ds (zeros for an empty slice).
// Sorts a copy; ds is small (fleet-sized) so this is cheap.
func durationStats(ds []time.Duration) (min, median, p90, max time.Duration) {
	if len(ds) == 0 {
		return 0, 0, 0, 0
	}
	s := make([]time.Duration, len(ds))
	copy(s, ds)
	sort.Slice(s, func(i, j int) bool { return s[i] < s[j] })
	return s[0], s[len(s)/2], s[(len(s)*9)/10], s[len(s)-1]
}
