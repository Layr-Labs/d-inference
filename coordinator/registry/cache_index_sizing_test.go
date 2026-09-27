package registry

import (
	"fmt"
	"testing"
	"time"
)

// The production shape the caps are sized for: 30 unique holders a second,
// each living a 25-minute TTL. Under the former 10,000-entry cap the index
// turned over in under six minutes; every holder must now live its whole TTL.
func TestCacheHoldersSurviveOperatorTTLAtFleetRate(t *testing.T) {
	const ratePerSecond = 30
	ttl := 25 * time.Minute
	total := ratePerSecond * int(ttl/time.Second)
	h := newCacheSizingHarness(t, ttl)
	start := h.clock.Now()
	first := h.donate(0)
	for index := 1; index < total; index++ {
		h.clock.Advance(time.Second / ratePerSecond)
		h.donate(index)
	}
	now := h.clock.Now()
	if !now.Before(start.Add(ttl)) {
		t.Fatalf("fill ran to %s, past the first holder's TTL", now.Sub(start))
	}

	lifecycle := h.r.CacheRoutingLifecycleStatus()
	if lifecycle.HolderAdded != uint64(total) {
		t.Fatalf("holder_added=%d want %d", lifecycle.HolderAdded, total)
	}
	for reason, count := range lifecycle.HolderRemoved {
		if count != 0 {
			t.Fatalf("%d holders removed for %q inside the TTL: %+v", count, reason, lifecycle.HolderRemoved)
		}
	}
	holders, attempts := h.r.CacheRoutingStateCounts()
	if holders != total {
		t.Fatalf("holders=%d want %d", holders, total)
	}
	// Terminal attempts leave after their own two-minute TTL, at most one
	// sweep interval late.
	maxAttempts := ratePerSecond * int((cacheRoutingAttemptTTL+cacheRoutingSweepInterval)/time.Second)
	if attempts == 0 || attempts > maxAttempts+ratePerSecond {
		t.Fatalf("attempts=%d, want 1..%d", attempts, maxAttempts+ratePerSecond)
	}
	if matches := h.matches(first, now); len(matches) != 1 {
		t.Fatalf("oldest holder unavailable %s into a %s TTL: %+v", now.Sub(start), ttl, matches)
	}

	expiry := start.Add(ttl)
	if matches := h.matches(first, expiry.Add(-time.Nanosecond)); len(matches) != 1 {
		t.Fatal("holder lapsed before its TTL")
	}
	if matches := h.matches(first, expiry); len(matches) != 0 {
		t.Fatalf("holder outlived its TTL: %+v", matches)
	}
	if h.removed(cacheHolderRemovalTTL) == 0 || h.removed(cacheHolderRemovalCapacityEviction) != 0 {
		t.Fatalf("expiry not attributed to ttl: %+v", h.r.CacheRoutingLifecycleStatus().HolderRemoved)
	}
}

func sizingTestHolder(tracker *cacheRoutingTracker, provider, tier string, at time.Time) cacheHolder {
	return cacheHolder{ProviderID: provider, UpdatedAt: at, ExpiresAt: at.Add(tracker.receiptTTL(tier))}
}

func (t *cacheRoutingTracker) sizingTestHas(key, provider string) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	_, held := t.holders[key][provider]
	_, ordered := t.holderOrderByRef[cacheHolderRef{key: key, providerID: provider}]
	return held && ordered
}

func TestCacheHolderCapEvictsSoonestExpiringFirst(t *testing.T) {
	tracker := newCacheRoutingTracker(10*time.Minute, defaultCacheRoutingMaxHolders)
	tracker.maxEntries = 3
	base := time.Unix(1_700_000_000, 0)
	put := func(key, tier string, after time.Duration) {
		t.Helper()
		tracker.mu.Lock()
		defer tracker.mu.Unlock()
		tracker.upsertHolderLocked(cacheTierKey(key, tier), sizingTestHolder(tracker, "provider", tier, base.Add(after)))
	}
	evictions := func() uint64 {
		tracker.mu.Lock()
		defer tracker.mu.Unlock()
		return tracker.holderRemoved[string(cacheHolderRemovalCapacityEviction)]
	}

	// The resident holder is updated after ssd-a yet expires nine minutes
	// before it: update order and expiry order disagree.
	put("ssd-a", "ssd", 0)                 // expires at 10m
	put("resident", "memory", time.Minute) // expires at 1m30s
	put("ssd-b", "ssd", 70*time.Second)    // expires at 11m10s
	put("ssd-c", "ssd", 80*time.Second)    // over the cap at 1m20s
	if tracker.sizingTestHas("memory:resident", "provider") {
		t.Fatal("the soonest-expiring holder survived the cap")
	}
	if !tracker.sizingTestHas("ssd-a", "provider") || !tracker.sizingTestHas("ssd-b", "provider") ||
		!tracker.sizingTestHas("ssd-c", "provider") {
		t.Fatal("the cap evicted a holder with more lifetime left")
	}
	if evictions() != 1 {
		t.Fatalf("capacity evictions=%d want 1", evictions())
	}

	// A refresh moves ssd-a behind ssd-b; the cap must follow the new expiry.
	put("ssd-a", "ssd", 2*time.Minute)   // now expires at 12m
	put("ssd-d", "ssd", 130*time.Second) // over the cap again
	if tracker.sizingTestHas("ssd-b", "provider") || !tracker.sizingTestHas("ssd-a", "provider") {
		t.Fatal("refreshing a holder did not move it in the eviction order")
	}
	if holders, heap, _, _ := tracker.indexSizes(); holders != 3 || heap != 3 || evictions() != 2 {
		t.Fatalf("holders=%d heap=%d evictions=%d", holders, heap, evictions())
	}
}

// An expired holder that the sweep has not reached yet is an expiry when the
// cap removes it: capacity_eviction counts only displaced live evidence.
func TestCacheHolderCapCountsExpiredHeadAsTTL(t *testing.T) {
	tracker := newCacheRoutingTracker(10*time.Minute, defaultCacheRoutingMaxHolders)
	tracker.maxEntries = 2
	base := time.Unix(1_700_000_000, 0)
	tracker.mu.Lock()
	tracker.upsertHolderLocked("memory:lapsed", sizingTestHolder(tracker, "provider", "memory", base))
	tracker.upsertHolderLocked("ssd-a", sizingTestHolder(tracker, "provider", "ssd", base))
	tracker.upsertHolderLocked("ssd-b", sizingTestHolder(tracker, "provider", "ssd", base.Add(5*time.Minute)))
	ttl := tracker.holderRemoved[string(cacheHolderRemovalTTL)]
	evicted := tracker.holderRemoved[string(cacheHolderRemovalCapacityEviction)]
	tracker.mu.Unlock()
	if ttl != 1 || evicted != 0 || tracker.sizingTestHas("memory:lapsed", "provider") ||
		!tracker.sizingTestHas("ssd-a", "provider") {
		t.Fatalf("ttl=%d capacity_eviction=%d", ttl, evicted)
	}
}

// Ten holders expire among 100,000 live ones. The ten were updated after
// most of the live set, so an update-ordered heap would hide them behind it.
func TestCacheSweepTouchesOnlyExpiredHolders(t *testing.T) {
	const live, expired = 100_000, 10
	tracker := newCacheRoutingTracker(25*time.Minute, defaultCacheRoutingMaxHolders)
	base := time.Unix(1_700_000_000, 0)
	fillSyntheticHolders(tracker, live, base)
	tracker.mu.Lock()
	for i := 0; i < expired; i++ {
		tracker.upsertHolderLocked(fmt.Sprintf("memory:short-%d", i),
			sizingTestHolder(tracker, "resident", "memory", base.Add(time.Minute)))
	}
	now := base.Add(2 * time.Minute)
	removed, examined := tracker.expireHoldersLocked(now, cacheRoutingMaxSweepRemovals)
	backlog := tracker.sweepLocked(now)
	ttl := tracker.holderRemoved[string(cacheHolderRemovalTTL)]
	sample, sampleLive := tracker.activeHolderLocked(fmt.Sprintf("filler-%036d", live/2), fmt.Sprintf("provider-%d", (live/2)%512), now)
	tracker.mu.Unlock()

	if removed != expired || examined != expired+1 {
		t.Fatalf("sweep removed %d and examined %d heap heads; want %d and %d", removed, examined, expired, expired+1)
	}
	if backlog {
		t.Fatal("a sweep far below its budget reported a backlog")
	}
	holders, heap, _, _ := tracker.indexSizes()
	if holders != live || heap != live || ttl != expired {
		t.Fatalf("holders=%d heap=%d ttl=%d", holders, heap, ttl)
	}
	if !sampleLive || !now.Before(sample.ExpiresAt) {
		t.Fatal("a live holder was disturbed by the sweep")
	}
	for i := 0; i < expired; i++ {
		if tracker.sizingTestHas(fmt.Sprintf("memory:short-%d", i), "resident") {
			t.Fatalf("expired holder %d survived", i)
		}
	}
}

// After a traffic lull longer than the TTL the whole index is stale. It must
// drain in bounded passes, and a stale holder that a pass has not reached yet
// must never be returned.
func TestCacheMassExpiryDrainsInBoundedSweeps(t *testing.T) {
	const total = 3*cacheRoutingMaxSweepRemovals + 100
	ttl := 25 * time.Minute
	h := newCacheSizingHarness(t, ttl)
	plans := make([]CachePlan, total)
	for index := range plans {
		plans[index] = h.donate(index)
	}
	tracker := h.r.cacheRouting
	if holders, _, attempts, _ := tracker.indexSizes(); holders != total || attempts != total {
		t.Fatalf("seeded holders=%d attempts=%d", holders, attempts)
	}
	if len(h.matches(plans[total-1], h.clock.Now())) != 1 {
		t.Fatal("seeded holder unavailable")
	}

	h.clock.Advance(ttl + time.Minute)
	now := h.clock.Now()
	sweeps := 0
	for remaining := total; remaining > 0; sweeps++ {
		if sweeps > total/cacheRoutingMaxSweepRemovals+1 {
			t.Fatalf("index not drained after %d sweeps: %d holders left", sweeps, remaining)
		}
		// Query from the back of the expiry order: the holder this pass reaches last.
		plan := plans[total-1-sweeps]
		if matches := h.matches(plan, now); len(matches) != 0 {
			t.Fatalf("sweep %d returned an expired holder: %+v", sweeps, matches)
		}
		holders, heap, attempts, attemptHeap := tracker.indexSizes()
		if heap != holders || attemptHeap != attempts {
			t.Fatalf("index drift: holders=%d heap=%d attempts=%d heap=%d", holders, heap, attempts, attemptHeap)
		}
		// One budget from the sweep plus the queried holder, which the lookup
		// itself expires when the sweep has not reached it.
		if drained := remaining - holders; drained > cacheRoutingMaxSweepRemovals+1 {
			t.Fatalf("sweep %d removed %d holders under the lock, budget %d", sweeps, drained, cacheRoutingMaxSweepRemovals)
		} else if holders > 0 && drained < cacheRoutingMaxSweepRemovals {
			t.Fatalf("sweep %d stopped at %d removals with %d expired holders left", sweeps, drained, holders)
		}
		remaining = holders
	}
	if sweeps != total/cacheRoutingMaxSweepRemovals+1 {
		t.Fatalf("drained in %d sweeps, want %d", sweeps, total/cacheRoutingMaxSweepRemovals+1)
	}
	if _, _, attempts, _ := tracker.indexSizes(); attempts != 0 {
		t.Fatalf("%d expired attempts survived the drain", attempts)
	}
	lifecycle := h.r.CacheRoutingLifecycleStatus()
	if lifecycle.HolderRemoved[string(cacheHolderRemovalTTL)] != total ||
		lifecycle.HolderRemoved[string(cacheHolderRemovalCapacityEviction)] != 0 {
		t.Fatalf("mass expiry attribution: %+v", lifecycle.HolderRemoved)
	}
	// The index serves fresh evidence again.
	fresh := h.donate(total)
	if len(h.matches(fresh, h.clock.Now())) != 1 {
		t.Fatal("fresh holder unavailable after the drain")
	}
}

// The status counts settle expiry before they count, in bounded passes.
func TestCacheStateCountsSettleMassExpiry(t *testing.T) {
	const total = 2*cacheRoutingMaxSweepRemovals + 7
	ttl := 25 * time.Minute
	h := newCacheSizingHarness(t, ttl)
	for index := 0; index < total; index++ {
		h.donate(index)
	}
	if holders, attempts := h.r.CacheRoutingStateCounts(); holders != total || attempts != total {
		t.Fatalf("holders=%d attempts=%d want %d", holders, attempts, total)
	}
	h.clock.Advance(ttl + time.Minute)
	if holders, attempts := h.r.CacheRoutingStateCounts(); holders != 0 || attempts != 0 {
		t.Fatalf("status counted expired entries: holders=%d attempts=%d", holders, attempts)
	}
	if got := h.removed(cacheHolderRemovalTTL); got != total {
		t.Fatalf("ttl removals=%d want %d", got, total)
	}
}

// A hit renews the holder. Sweeps at the original deadline must leave it, and
// the sweep at the renewed deadline must take it.
func TestCacheHolderRefreshMovesItsExpiry(t *testing.T) {
	ttl := 25 * time.Minute
	h := newCacheSizingHarness(t, ttl)
	start := h.clock.Now()
	plan := h.donate(0)
	neighbour := h.donate(1)

	h.clock.Advance(20 * time.Minute)
	h.hit(0)
	renewed := h.clock.Now().Add(ttl)

	h.clock.Advance(5*time.Minute + time.Second) // past the original deadline
	now := h.clock.Now()
	if !now.After(start.Add(ttl)) {
		t.Fatal("clock did not pass the original deadline")
	}
	if holders, _ := h.r.CacheRoutingStateCounts(); holders != 1 {
		t.Fatalf("holders=%d, want only the renewed one", holders)
	}
	if len(h.matches(neighbour, now)) != 0 {
		t.Fatal("holder that was never renewed survived its TTL")
	}
	matches := h.matches(plan, now)
	if len(matches) != 1 || !matches[0].Holder.ExpiresAt.Equal(renewed) {
		t.Fatalf("renewed holder lost or not re-dated: %+v", matches)
	}

	h.clock.Advance(renewed.Sub(now))
	if holders, _ := h.r.CacheRoutingStateCounts(); holders != 0 {
		t.Fatalf("holders=%d after the renewed deadline", holders)
	}
	if len(h.matches(plan, h.clock.Now())) != 0 {
		t.Fatal("renewed holder outlived its renewed TTL")
	}
	if got := h.removed(cacheHolderRemovalTTL); got != 2 {
		t.Fatalf("ttl removals=%d want 2", got)
	}
}

// An attempt's deadline is rewritten when it turns terminal (two hours in
// flight, two minutes after), so creation order is not expiry order.
func TestCacheAttemptSweepAndCapFollowExpiry(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, defaultCacheRoutingMaxHolders)
	tracker.maxAttempts = 2
	base := time.Unix(1_700_000_000, 0)
	store := func(nonce string, after time.Duration) {
		t.Helper()
		created := base.Add(after)
		tracker.mu.Lock()
		defer tracker.mu.Unlock()
		tracker.storeAttemptLocked(nonce, cacheAttempt{
			RequestID: nonce, ProviderID: "provider", CreatedAt: created,
			ExpiresAt: created.Add(cacheRoutingInFlightAttemptTTL),
		})
		tracker.enforceAttemptCapLocked()
	}
	has := func(nonce string) bool {
		tracker.mu.Lock()
		defer tracker.mu.Unlock()
		_, held := tracker.attempts[nonce]
		_, ordered := tracker.attemptOrderByNonce[nonce]
		return held && ordered
	}

	store("in-flight", 0)
	store("finished", time.Second)
	tracker.markAttemptTerminal("finished", base.Add(10*time.Second))

	tracker.mu.Lock()
	early := tracker.expireAttemptsLocked(base.Add(time.Minute), cacheRoutingMaxSweepRemovals)
	tracker.mu.Unlock()
	if early != 0 || !has("finished") {
		t.Fatal("terminal attempt expired before its two-minute TTL")
	}

	// At the cap the terminal attempt, which expires first, goes before the
	// older in-flight one.
	store("second-in-flight", 20*time.Second)
	if has("finished") || !has("in-flight") || !has("second-in-flight") {
		t.Fatal("attempt cap evicted an in-flight attempt before a terminal one")
	}

	tracker.markAttemptTerminal("second-in-flight", base.Add(30*time.Second))
	tracker.mu.Lock()
	removed := tracker.expireAttemptsLocked(base.Add(30*time.Second+cacheRoutingAttemptTTL), cacheRoutingMaxSweepRemovals)
	tracker.mu.Unlock()
	if removed != 1 || has("second-in-flight") || !has("in-flight") {
		t.Fatalf("sweep removed %d attempts; the terminal one must go and the older in-flight one stay", removed)
	}
	if _, _, attempts, heap := tracker.indexSizes(); attempts != 1 || heap != 1 {
		t.Fatalf("attempts=%d heap=%d", attempts, heap)
	}
}

func TestCacheIndexCapsCoverSizingTTL(t *testing.T) {
	seconds := int(cacheRoutingSizingTTL / time.Second)
	if cacheRoutingMaxEntries < 4*30*seconds {
		t.Fatalf("holder cap %d lacks 4x headroom over 30 holders/s for %s", cacheRoutingMaxEntries, cacheRoutingSizingTTL)
	}
	if cacheDemandMaxEntries < 300*seconds {
		t.Fatalf("demand cap %d does not hold %s at 300 entries/s", cacheDemandMaxEntries, cacheRoutingSizingTTL)
	}
	tracker := newCacheRoutingTracker(cacheRoutingSizingTTL, defaultCacheRoutingMaxHolders)
	if tracker.maxEntries != cacheRoutingMaxEntries || tracker.demand.limit != cacheDemandMaxEntries ||
		tracker.demand.ttl != cacheRoutingSizingTTL {
		t.Fatalf("tracker caps: holders=%d demand=%d ttl=%s", tracker.maxEntries, tracker.demand.limit, tracker.demand.ttl)
	}
}
