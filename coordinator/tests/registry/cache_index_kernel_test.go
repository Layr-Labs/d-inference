package registry_test

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheindex"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
)

func TestCacheHolderCapEvictsSoonestExpiringFirst(t *testing.T) {
	tracker := newCacheIndexKernelFixture(cachetracker.Settings{TTL: 10 * time.Minute, MaxHolders: indexKernelMaxHolders, MaxEntries: 3, MaxAttempts: indexKernelMaxAttempts})
	base := time.Unix(1_700_000_000, 0)
	put := func(key, tier string, after time.Duration) {
		t.Helper()
		tracker.UpsertHolderLocked(cachetracker.CacheTierKey(key, tier), indexKernelTestHolder(tracker, "provider", tier, base.Add(after)))
	}
	evictions := func() uint64 {
		return indexKernelMetrics(tracker).Removed["capacity_eviction"]
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
	tracker := newCacheIndexKernelFixture(cachetracker.Settings{TTL: 10 * time.Minute, MaxHolders: indexKernelMaxHolders, MaxEntries: 2, MaxAttempts: indexKernelMaxAttempts})
	base := time.Unix(1_700_000_000, 0)
	tracker.UpsertHolderLocked("memory:lapsed", indexKernelTestHolder(tracker, "provider", "memory", base))
	tracker.UpsertHolderLocked("ssd-a", indexKernelTestHolder(tracker, "provider", "ssd", base))
	tracker.UpsertHolderLocked("ssd-b", indexKernelTestHolder(tracker, "provider", "ssd", base.Add(5*time.Minute)))
	ttl := indexKernelMetrics(tracker).Removed["ttl"]
	evicted := indexKernelMetrics(tracker).Removed["capacity_eviction"]
	if ttl != 1 || evicted != 0 || tracker.sizingTestHas("memory:lapsed", "provider") ||
		!tracker.sizingTestHas("ssd-a", "provider") {
		t.Fatalf("ttl=%d capacity_eviction=%d", ttl, evicted)
	}
}

// Ten holders expire among 100,000 live ones. The ten were updated after
// most of the live set, so an update-ordered heap would hide them behind it.
func TestCacheSweepTouchesOnlyExpiredHolders(t *testing.T) {
	const live, expired = 100_000, 10
	tracker := newCacheIndexKernelFixture(cachetracker.Settings{TTL: 25 * time.Minute, MaxHolders: indexKernelMaxHolders, MaxEntries: indexKernelMaxEntries, MaxAttempts: indexKernelMaxAttempts})
	base := time.Unix(1_700_000_000, 0)
	fillIndexKernelHolders(tracker, live, base)
	for i := 0; i < expired; i++ {
		tracker.UpsertHolderLocked(fmt.Sprintf("memory:short-%d", i),
			indexKernelTestHolder(tracker, "resident", "memory", base.Add(time.Minute)))
	}
	now := base.Add(2 * time.Minute)
	removed, examined := tracker.ExpireHoldersLocked(now, indexKernelSweepRemovals)
	backlog := tracker.SweepLocked(now)
	ttl := indexKernelMetrics(tracker).Removed["ttl"]
	sample, sampleLive := tracker.ActiveHolderLocked(fmt.Sprintf("filler-%036d", live/2), fmt.Sprintf("provider-%d", (live/2)%512), now)

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

// An attempt's deadline is rewritten when it turns terminal (two hours in
// flight, two minutes after), so creation order is not expiry order.
func TestCacheAttemptSweepAndCapFollowExpiry(t *testing.T) {
	tracker := newCacheIndexKernelFixture(cachetracker.Settings{TTL: time.Minute, MaxHolders: indexKernelMaxHolders, MaxEntries: indexKernelMaxEntries, MaxAttempts: 2})
	base := time.Unix(1_700_000_000, 0)
	store := func(nonce string, after time.Duration) {
		t.Helper()
		created := base.Add(after)
		tracker.StoreAttemptLocked(nonce, indexKernelAttempt{
			RequestID: nonce, ProviderID: "provider", CreatedAt: created,
			ExpiresAt: created.Add(indexKernelInFlightAttemptTTL),
		})
		tracker.EnforceAttemptCapLocked()
	}
	has := func(nonce string) bool {
		_, held := tracker.config.Attempts.Load(nonce)
		ordered := tracker.config.AttemptOrder.Load(nonce) != nil
		return held && ordered
	}

	store("in-flight", 0)
	store("finished", time.Second)
	tracker.MarkAttemptTerminal("finished", base.Add(10*time.Second))

	early := tracker.ExpireAttemptsLocked(base.Add(time.Minute), indexKernelSweepRemovals)
	if early != 0 || !has("finished") {
		t.Fatal("terminal attempt expired before its two-minute TTL")
	}

	// At the cap the terminal attempt, which expires first, goes before the
	// older in-flight one.
	store("second-in-flight", 20*time.Second)
	if has("finished") || !has("in-flight") || !has("second-in-flight") {
		t.Fatal("attempt cap evicted an in-flight attempt before a terminal one")
	}

	tracker.MarkAttemptTerminal("second-in-flight", base.Add(30*time.Second))
	removed := tracker.ExpireAttemptsLocked(base.Add(30*time.Second+indexKernelAttemptTTL), indexKernelSweepRemovals)
	if removed != 1 || has("second-in-flight") || !has("in-flight") {
		t.Fatalf("sweep removed %d attempts; the terminal one must go and the older in-flight one stay", removed)
	}
	if _, _, attempts, heap := tracker.indexSizes(); attempts != 1 || heap != 1 {
		t.Fatalf("attempts=%d heap=%d", attempts, heap)
	}
}

// The per-bucket maxHolders eviction follows the same attribution as the
// global cap. Resident holders live 30 s, the sweep interval, so the bucket's
// victim has often expired without having been swept.
func TestCacheBucketEvictionCountsExpiredVictimAsTTL(t *testing.T) {
	tracker := newCacheIndexKernelFixture(cachetracker.Settings{TTL: 10 * time.Minute, MaxHolders: 2, MaxEntries: indexKernelMaxEntries, MaxAttempts: indexKernelMaxAttempts})
	base := time.Unix(1_700_000_000, 0)
	counts := func() (ttl, evicted uint64) {
		return indexKernelMetrics(tracker).Removed["ttl"],
			indexKernelMetrics(tracker).Removed["capacity_eviction"]
	}
	tracker.SweepIfDueLocked(base.Add(-5 * time.Second))
	tracker.UpsertHolderLocked("memory:k", indexKernelTestHolder(tracker, "p1", "memory", base))
	tracker.UpsertHolderLocked("memory:k", indexKernelTestHolder(tracker, "p2", "memory", base.Add(20*time.Second)))
	tracker.SweepIfDueLocked(base.Add(29 * time.Second)) // p1 expires at 30 s
	// At 45 s p1 expired 15 s ago and the next interval sweep is not due.
	at := base.Add(45 * time.Second)
	tracker.SweepIfDueLocked(at)
	if _, unswept := tracker.config.Holders.Bucket("memory:k").Load("p1"); !unswept {
		t.Fatal("the expired holder was swept; the bucket cap has nothing to attribute")
	}
	tracker.UpsertHolderLocked("memory:k", indexKernelTestHolder(tracker, "p3", "memory", at))
	if ttl, evicted := counts(); ttl != 1 || evicted != 0 {
		t.Fatalf("expired bucket victim: ttl=%d capacity_eviction=%d, want 1/0", ttl, evicted)
	}
	// A live victim is still a capacity eviction.
	tracker.UpsertHolderLocked("memory:k", indexKernelTestHolder(tracker, "p4", "memory", at.Add(time.Second)))
	if ttl, evicted := counts(); ttl != 1 || evicted != 1 {
		t.Fatalf("live bucket victim: ttl=%d capacity_eviction=%d, want 1/1", ttl, evicted)
	}
	if _, kept := tracker.config.Holders.Bucket("memory:k").Load("p2"); kept || tracker.config.Holders.Bucket("memory:k").Count() != 2 {
		t.Fatalf("bucket did not evict its oldest holder: %+v", tracker.config.Holders.Bucket("memory:k"))
	}
}

// Known edge of evicting the soonest expiry: at a full index of long-lived
// SSD holders a resident holder, which lives 30 s, is its own victim.
func TestCacheResidentHolderAtFullIndexIsTheCapVictim(t *testing.T) {
	tracker := newCacheIndexKernelFixture(cachetracker.Settings{TTL: 25 * time.Minute, MaxHolders: indexKernelMaxHolders, MaxEntries: 3, MaxAttempts: indexKernelMaxAttempts})
	base := time.Unix(1_700_000_000, 0)
	for i := 0; i < 3; i++ {
		tracker.UpsertHolderLocked(fmt.Sprintf("ssd-%d", i), indexKernelTestHolder(tracker, "p", "ssd", base))
	}
	tracker.UpsertHolderLocked("memory:new", indexKernelTestHolder(tracker, "p", "memory", base.Add(time.Minute)))
	_, kept := tracker.config.Holders.Bucket("memory:new").Load("p")
	evicted := indexKernelMetrics(tracker).Removed["capacity_eviction"]
	if kept || tracker.config.Holders.Len() != 3 || indexKernelMetrics(tracker).Added != 4 || evicted != 1 {
		t.Fatalf("kept=%v holders=%d holder_added=%d capacity_eviction=%d",
			kept, tracker.config.Holders.Len(), indexKernelMetrics(tracker).Added, evicted)
	}
}

// A pass that ends exactly on its budget with nothing expired left must not
// re-arm the sweep.
func TestCacheSweepExactBudgetLeavesNoBacklog(t *testing.T) {
	tracker := newCacheIndexKernelFixture(cachetracker.Settings{TTL: 25 * time.Minute, MaxHolders: indexKernelMaxHolders, MaxEntries: indexKernelMaxEntries, MaxAttempts: indexKernelMaxAttempts})
	base := time.Unix(1_700_000_000, 0)
	fillIndexKernelHolders(tracker, indexKernelSweepRemovals, base)
	tracker.UpsertHolderLocked("live", indexKernelTestHolder(tracker, "p", "ssd", base.Add(20*time.Minute)))
	backlog := tracker.SweepLocked(base.Add(26 * time.Minute))
	left := tracker.config.Holders.Len()
	if backlog || left != 1 {
		t.Fatalf("backlog=%v holders left=%d, want false and the live one", backlog, left)
	}
	fillIndexKernelHolders(tracker, indexKernelSweepRemovals+1, base)
	backlog = tracker.SweepLocked(base.Add(26 * time.Minute))
	left = tracker.config.Holders.Len()
	if !backlog || left != 2 {
		t.Fatalf("backlog=%v holders left=%d, want true with one expired and one live", backlog, left)
	}
}

// If the heaps and the maps ever drifted apart, cap enforcement must leave
// the index over its cap instead of indexing an empty heap.
func TestCacheCapEnforcementSurvivesIndexDrift(t *testing.T) {
	tracker := newCacheIndexKernelFixture(cachetracker.Settings{TTL: time.Minute, MaxHolders: indexKernelMaxHolders, MaxEntries: 1, MaxAttempts: 1})
	now := time.Unix(1_700_000_000, 0)
	for i := 0; i < 5; i++ {
		tracker.config.Holders.Store(cacheindex.HolderRef{Key: fmt.Sprint(i), ProviderID: "drifted"}, indexKernelHolder{})
	}
	{
		tracker.config.Attempts.Store("a", indexKernelAttempt{})
		tracker.config.Attempts.Store("b", indexKernelAttempt{})
	}
	tracker.EnforceCapLocked(now)
	tracker.EnforceAttemptCapLocked()
	if backlog := tracker.SweepLocked(now); backlog {
		t.Fatal("empty heaps reported a sweep backlog")
	}
	if tracker.config.Holders.Len() != 5 || tracker.config.Attempts.Len() != 2 {
		t.Fatalf("drifted state was rewritten: holders=%d attempts=%d", tracker.config.Holders.Len(), tracker.config.Attempts.Len())
	}
}
