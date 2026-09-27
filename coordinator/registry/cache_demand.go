package registry

import (
	"container/list"
	"slices"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
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

// cacheDemandMaxExpiryPerObserve bounds the synchronous TTL sweep that runs
// under d.mu on the plan path. After a lull longer than the TTL the whole index
// (up to cacheDemandMaxEntries) is stale; draining it in one locked pass would
// stall planning, so each observe expires at most this many head entries and
// later calls finish the job. Correctness never depends on the sweep: every
// match is validated against its own timestamp, so a stale entry that is still
// present cannot match, and the entry cap still evicts from the same head.
const cacheDemandMaxExpiryPerObserve = 1_024

func newCacheDemandTracker(limit int, ttl time.Duration) *cacheDemandTracker {
	return &cacheDemandTracker{limit: max(1, limit), ttl: ttl, entries: make(map[string]*list.Element)}
}

func (d *cacheDemandTracker) observe(boundaries []cacheDemandBoundary, now time.Time) (int, string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	for expired := 0; expired < cacheDemandMaxExpiryPerObserve; expired++ {
		first := d.order.Front()
		if first == nil || now.Sub(first.Value.(cacheDemandEntry).seen) < d.ttl {
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

const (
	// cacheDemandStrideTokens spaces the observed boundaries. The provider
	// engine keeps a checkpoint at every multiple of 1,024 tokens and none
	// below its 1,024-token floor (minEffectiveTokens), and it uses the
	// observed repeat to choose the checkpoint at or below it. A boundary
	// between two multiples, or below the first, names a prefix that can be
	// neither written nor restored.
	cacheDemandStrideTokens = 4 * int(promptcontract.BlockSize)
	// cacheDemandMaxStrideBoundaries bounds one plan's stride observations.
	// A prompt longer than 64 × 1,024 tokens keeps its deepest 64: those are
	// the ones worth restoring, and its shallow prefix is what shorter plans
	// observe.
	cacheDemandMaxStrideBoundaries = 64
)

// cacheDemandAnchors selects what a plan observes: its deepest
// cacheDemandMaxStrideBoundaries boundaries on the 1,024-token stride and
// its final boundary, which need not be on the stride. The result is at most
// cacheDemandMaxStrideBoundaries + 1 anchors, shallowest first. Selection is
// by token count, so it does not depend on the plan listing every block.
func cacheDemandAnchors(boundaries []protocol.PrefixCacheAnchor) []protocol.PrefixCacheAnchor {
	last := len(boundaries) - 1
	selected := make([]protocol.PrefixCacheAnchor, 0,
		min(len(boundaries), cacheDemandMaxStrideBoundaries+1))
	strides := 0
	for i := last; i >= 0 && strides < cacheDemandMaxStrideBoundaries; i-- {
		onStride := boundaries[i].TokenCount%cacheDemandStrideTokens == 0
		if onStride {
			strides++
		}
		if onStride || i == last {
			selected = append(selected, boundaries[i])
		}
	}
	slices.Reverse(selected)
	return selected
}

func (t *cacheRoutingTracker) observeCacheDemand(plan *CachePlan, routeKey []byte, now time.Time) {
	if t == nil || plan == nil || plan.generation != t.generation || t.generation.revoked.Load() || !plan.present() {
		return
	}
	// The same anchors are read and then recorded, so one plan costs at most
	// cacheDemandMaxStrideBoundaries + 1 = 65 keyed digests and index entries
	// whatever its length. Full holder lookup still checks EVERY boundary.
	anchors := cacheDemandAnchors(plan.Boundaries)
	boundaries := make([]cacheDemandBoundary, 0, len(anchors))
	for _, anchor := range anchors {
		key := cacheBoundaryKey(routeKey, *plan, anchor)
		if key != "" {
			boundaries = append(boundaries, cacheDemandBoundary{key, anchor.TokenCount})
		}
	}
	plan.RepeatedPrefixTokens, plan.affinityKey = t.demand.observe(boundaries, now)
}
