package registry

import (
	"container/list"
	"slices"
	"sort"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
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
	// onTouched receives the keys an observe inserted or refreshed, after
	// d.mu is released. Nil when nothing persists the index.
	onTouched func(keys []string, now time.Time)
	// capEvictions counts entries the cap removed while they were still
	// inside the TTL. Each one is a repeat that may now read as novel.
	capEvictions uint64
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

func (d *cacheDemandTracker) setOnTouched(fn func(keys []string, now time.Time)) {
	d.mu.Lock()
	d.onTouched = fn
	d.mu.Unlock()
}

func (d *cacheDemandTracker) observe(boundaries []cacheDemandBoundary, now time.Time) (int, string) {
	longest, affinity, touched, onTouched := d.observeLocked(boundaries, now)
	if onTouched != nil && len(touched) > 0 {
		onTouched(touched, now)
	}
	return longest, affinity
}

func (d *cacheDemandTracker) observeLocked(boundaries []cacheDemandBoundary, now time.Time) (int, string, []string, func([]string, time.Time)) {
	d.mu.Lock()
	defer d.mu.Unlock()
	var touched []string
	for expired := 0; expired < cacheDemandMaxExpiryPerObserve; expired++ {
		first := d.order.Front()
		if first == nil || now.Sub(first.Value.(cacheDemandEntry).seen) < d.ttl {
			break
		}
		delete(d.entries, first.Value.(cacheDemandEntry).key)
		d.order.Remove(first)
	}
	// The repeat is the deepest boundary that matched. Affinity is keyed by
	// the deepest matched rung instead (cacheDemandAffinityRung), so a growing
	// conversation keeps one key until it doubles, and falls back to the
	// deepest match when no rung matched, which is how a prompt under 1,024
	// tokens matches on its final boundary.
	longest, deepest, rung, affinity := 0, "", 0, ""
	// Read the old set before inserting: a request cannot match itself.
	for _, boundary := range boundaries {
		entry := d.entries[boundary.key]
		if entry == nil {
			continue
		}
		// Concurrent callers can acquire the lock in a different order from
		// their timestamp samples. Validate each match independently of the
		// eviction list's insertion order.
		if age := now.Sub(entry.Value.(cacheDemandEntry).seen); age < 0 || age >= d.ttl {
			continue
		}
		if boundary.tokens > longest {
			longest, deepest = boundary.tokens, boundary.key
		}
		if boundary.tokens > rung && cacheDemandAffinityRung(boundary.tokens) {
			rung, affinity = boundary.tokens, boundary.key
		}
	}
	if affinity == "" {
		affinity = deepest
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
		if d.onTouched != nil {
			touched = append(touched, boundary.key)
		}
		for len(d.entries) > d.limit {
			first := d.order.Front()
			evicted := first.Value.(cacheDemandEntry)
			// A head past its TTL that the bounded sweep has not reached is
			// an expiry, not a cap eviction.
			if now.Sub(evicted.seen) < d.ttl {
				d.capEvictions++
			}
			delete(d.entries, evicted.key)
			d.order.Remove(first)
		}
	}
	return longest, affinity, touched, d.onTouched
}

// restore seeds the index from durable rows, oldest first so the eviction
// order matches the seen order. Rows past the TTL are skipped; the entry cap
// keeps the newest.
// restore seeds the index from the durable copy and returns the entries it
// accepted (within the TTL, not in the future); the caller treats those as
// already persisted. Restored entries are merged into the recency list by
// seen time rather than appended: a restore retried after traffic has
// populated the index (cachepersist) must not evict fresher live
// observations to keep older durable ones, so the capped merge keeps the
// newest entries across both sets.
func (d *cacheDemandTracker) restore(records []crs.DemandRecord, now time.Time) []crs.DemandRecord {
	sort.Slice(records, func(i, j int) bool { return records[i].SeenAt.Before(records[j].SeenAt) })
	d.mu.Lock()
	defer d.mu.Unlock()
	valid := make([]crs.DemandRecord, 0, len(records))
	// Records arrive oldest first, so the insertion point only ever moves
	// toward the back: one pass over the list in total.
	var after *list.Element
	for _, rec := range records {
		if rec.Key == "" || now.Sub(rec.SeenAt) >= d.ttl || rec.SeenAt.After(now) {
			continue
		}
		valid = append(valid, rec)
		if existing := d.entries[rec.Key]; existing != nil {
			if !rec.SeenAt.After(existing.Value.(cacheDemandEntry).seen) {
				continue
			}
			if after == existing {
				after = existing.Prev()
			}
			d.order.Remove(existing)
			delete(d.entries, rec.Key)
		}
		next := d.order.Front()
		if after != nil {
			next = after.Next()
		}
		for next != nil && !next.Value.(cacheDemandEntry).seen.After(rec.SeenAt) {
			after, next = next, next.Next()
		}
		entry := cacheDemandEntry{rec.Key, rec.SeenAt}
		if after == nil {
			after = d.order.PushFront(entry)
		} else {
			after = d.order.InsertAfter(entry, after)
		}
		d.entries[rec.Key] = after
		for len(d.entries) > d.limit {
			first := d.order.Front()
			if first == after {
				after = nil
			}
			delete(d.entries, first.Value.(cacheDemandEntry).key)
			d.order.Remove(first)
		}
	}
	// Only an entry the index still holds at the end counts as persisted;
	// one the cap evicted, even by a later record of this same restore,
	// must be written again when it is next observed.
	accepted := valid[:0]
	for _, rec := range valid {
		if _, kept := d.entries[rec.Key]; kept {
			accepted = append(accepted, rec)
		}
	}
	return accepted
}

// stats reports the entries held, including expired ones the bounded sweep
// has not reached, and the cap evictions so far.
// clear drops every entry. A retired tracker (ConfigureCacheRouting replaced
// it) can stay reachable through a prepared attempt's owner until that request
// finishes; without this the retired generation would pin up to
// cacheDemandMaxEntries entries. observe already refuses a revoked generation.
func (d *cacheDemandTracker) clear() {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.order.Init()
	d.entries = make(map[string]*list.Element)
}

func (d *cacheDemandTracker) stats() (entries int, capEvictions uint64) {
	d.mu.Lock()
	defer d.mu.Unlock()
	return len(d.entries), d.capEvictions
}

const (
	// cacheDemandStrideTokens spaces the observed boundaries to match the two
	// provider consumers of the reported repeat. The engine's historical
	// checkpoint retention keeps the 1,024-aligned boundary at or below it
	// (CBv2Request.prefixCheckpointTargetTokens, which the provider bridge
	// sets from RemotePrefixCacheContext.repeatedPrefixTokens; it lands with
	// the checkpoint-geometry change), and SSDCheckpointDemand.admitsWrite
	// gates the write on repeatedPrefixTokens >= minEffectiveTokens, which is
	// 1,024. A boundary between two multiples, or below the first, names a
	// prefix that can be neither written nor restored.
	cacheDemandStrideTokens = 4 * int(promptcontract.BlockSize)
	// cacheDemandMaxStrideBoundaries is the window: one plan observes its
	// deepest 64 boundaries on the stride, which are the ones worth restoring.
	cacheDemandMaxStrideBoundaries = 64
	// cacheDemandMaxLadderBoundaries bounds the rungs a plan longer than the
	// window observes below it: 1,024 × 2^0 … 2^9 are the rungs a plan of
	// cacheRoutingMaxReceiptTokens can have. A prompt under 131,072 tokens
	// has at most six below its window (1,024 … 32,768).
	cacheDemandMaxLadderBoundaries = 10
	// cacheDemandMaxPlanBoundaries is what one plan reads and records at
	// most, whatever its length: the window, the final boundary and the
	// ladder. It is 71 for a prompt under 131,072 tokens and 65 up to 65,536.
	cacheDemandMaxPlanBoundaries = cacheDemandMaxStrideBoundaries + 1 + cacheDemandMaxLadderBoundaries
)

// cacheDemandAffinityRung reports a power-of-two multiple of 1,024 tokens:
// 1,024, 2,048, 4,096, 8,192 and so on.
func cacheDemandAffinityRung(tokens int) bool {
	strides := tokens / cacheDemandStrideTokens
	return tokens > 0 && tokens%cacheDemandStrideTokens == 0 && strides&(strides-1) == 0
}

// cacheDemandAnchors selects what a plan observes, shallowest first:
//
//   - the window: its deepest cacheDemandMaxStrideBoundaries boundaries on
//     the 1,024-token stride;
//   - its final boundary, which need not be on the stride;
//   - the ladder, for a plan longer than the window only: the rungs
//     (cacheDemandAffinityRung) below the window. Without it a plan over
//     65,536 tokens reports no repeat for a shallow shared prefix, such as a
//     system prompt and tool block, and the provider skips the write as
//     skipped_novel.
//
// Selection is by token count, so it does not depend on the plan listing
// every block.
func cacheDemandAnchors(boundaries []protocol.PrefixCacheAnchor) []protocol.PrefixCacheAnchor {
	last := len(boundaries) - 1
	selected := make([]protocol.PrefixCacheAnchor, 0,
		min(len(boundaries), cacheDemandMaxPlanBoundaries))
	i, strides := last, 0
	for ; i >= 0 && strides < cacheDemandMaxStrideBoundaries; i-- {
		onStride := boundaries[i].TokenCount%cacheDemandStrideTokens == 0
		if onStride {
			strides++
		}
		if onStride || i == last {
			selected = append(selected, boundaries[i])
		}
	}
	for ; i >= 0; i-- {
		if cacheDemandAffinityRung(boundaries[i].TokenCount) {
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
	// cacheDemandMaxPlanBoundaries = 75 keyed digests and index entries
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
