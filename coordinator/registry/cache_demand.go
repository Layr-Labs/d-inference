package registry

import (
	"container/list"
	"sync"
	"time"
)

// Demand is advisory, never cache evidence. Only keyed, tenant/build-scoped
// boundary digests live here, for at most the routing TTL and a fixed entry cap.
// It carries no prompt payload, token IDs, provider claims or durable state.
type cacheDemandTracker struct {
	mu      sync.Mutex
	limit   int
	ttl     time.Duration
	order   list.List
	entries map[string]*list.Element
}

type cacheDemandEntry struct {
	key  string
	seen time.Time
}

type cacheDemandBoundary struct {
	key    string
	tokens int
}

func newCacheDemandTracker(limit int, ttl time.Duration) *cacheDemandTracker {
	return &cacheDemandTracker{limit: max(1, limit), ttl: ttl, entries: make(map[string]*list.Element)}
}

func (d *cacheDemandTracker) observe(boundaries []cacheDemandBoundary, now time.Time) (int, string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	for first := d.order.Front(); first != nil; first = d.order.Front() {
		if now.Sub(first.Value.(cacheDemandEntry).seen) < d.ttl {
			break
		}
		delete(d.entries, first.Value.(cacheDemandEntry).key)
		d.order.Remove(first)
	}
	longest, affinity := 0, ""
	// Read the old set before inserting: a request cannot match itself.
	for _, boundary := range boundaries {
		if entry := d.entries[boundary.key]; entry != nil && boundary.tokens > longest {
			age := now.Sub(entry.Value.(cacheDemandEntry).seen)
			// Concurrent callers can acquire the lock in a different order
			// from their timestamp samples. Validate each match independently
			// of the eviction list's insertion order.
			if age >= 0 && age < d.ttl {
				longest, affinity = boundary.tokens, boundary.key
			}
		}
	}
	for _, boundary := range boundaries {
		if boundary.key == "" {
			continue
		}
		if entry := d.entries[boundary.key]; entry != nil {
			previous := entry.Value.(cacheDemandEntry)
			if now.Before(previous.seen) {
				continue
			}
			entry.Value = cacheDemandEntry{boundary.key, now}
			d.order.MoveToBack(entry)
		} else {
			d.entries[boundary.key] = d.order.PushBack(cacheDemandEntry{boundary.key, now})
		}
		for len(d.entries) > d.limit {
			first := d.order.Front()
			delete(d.entries, first.Value.(cacheDemandEntry).key)
			d.order.Remove(first)
		}
	}
	return longest, affinity
}

func (t *cacheRoutingTracker) observeCacheDemand(plan *CachePlan, routeKey []byte, now time.Time) {
	if t == nil || plan == nil || plan.generation != t.generation || t.generation.Revoked() || !plan.present() {
		return
	}
	// Geometric anchors plus the final endpoint bound work and metadata to
	// O(log(prompt length)). Full holder lookup still checks EVERY boundary.
	boundaries := make([]cacheDemandBoundary, 0, 16)
	for i, anchor := range plan.Boundaries {
		n := i + 1
		if n&(n-1) != 0 && n != len(plan.Boundaries) {
			continue
		}
		key := cacheBoundaryKey(routeKey, *plan, anchor)
		if key != "" {
			boundaries = append(boundaries, cacheDemandBoundary{key, anchor.TokenCount})
		}
	}
	plan.RepeatedPrefixTokens, plan.affinityKey = t.demand.observe(boundaries, now)
}
