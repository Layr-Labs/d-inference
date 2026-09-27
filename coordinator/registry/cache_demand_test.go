package registry

import (
	"fmt"
	"sync"
	"testing"
	"time"
)

func TestCacheDemandIsBoundedSlidingAndDoesNotMatchItself(t *testing.T) {
	now := time.Unix(1000, 0)
	d := newCacheDemandTracker(2, time.Minute)
	values := []cacheDemandBoundary{{"short", 256}, {"long", 1024}}
	if n, key := d.observe(values, now); n != 0 || key != "" {
		t.Fatalf("first observation matched itself: %d %q", n, key)
	}
	if n, key := d.observe(values, now.Add(30*time.Second)); n != 1024 || key != "long" {
		t.Fatalf("repeat=%d %q", n, key)
	}
	if n, _ := d.observe(values, now.Add(80*time.Second)); n != 1024 {
		t.Fatal("live sliding history expired")
	}
	if n, _ := d.observe(values, now.Add(141*time.Second)); n != 0 {
		t.Fatal("expired demand survived")
	}
	d.observe([]cacheDemandBoundary{{"third", 2048}}, now.Add(142*time.Second))
	if len(d.entries) != 2 || d.order.Len() != 2 {
		t.Fatal("unbounded demand metadata")
	}
	if _, ok := d.entries["short"]; ok {
		t.Fatal("oldest entry not evicted")
	}
}

func TestCacheDemandScopeBuildAndGenerationIsolation(t *testing.T) {
	r, _, _ := exactTestRegistry(t)
	plan := boundTestCachePlan(r, exactTestPlan(exactTestAnchor(1, "c")))
	key := []byte("private-route-key")
	for _, change := range []string{"scope", "build", "contract", "generation"} {
		t.Run(change, func(t *testing.T) {
			tracker := newCacheRoutingTracker(time.Minute, 4)
			first := plan
			first.generation = tracker.generation
			tracker.observeCacheDemand(&first, key, time.Now())
			other := first
			other.RepeatedPrefixTokens = 0
			other.affinityKey = ""
			switch change {
			case "scope":
				other.CacheScope += "other"
			case "build":
				other.ModelAggregateHash = "d" + other.ModelAggregateHash[1:]
			case "contract":
				other.PromptContractID = "d" + other.PromptContractID[1:]
			case "generation":
				other.generation = &cacheRoutingGeneration{}
			}
			tracker.observeCacheDemand(&other, key, time.Now())
			if other.RepeatedPrefixTokens != 0 || other.affinityKey != "" {
				t.Fatal("demand crossed identity boundary")
			}
			again := first
			tracker.observeCacheDemand(&again, key, time.Now())
			if again.RepeatedPrefixTokens != 256 || again.affinityKey == "" {
				t.Fatal("same identity did not match")
			}
		})
	}
}

func TestCacheDemandConcurrentCapacity(t *testing.T) {
	d := newCacheDemandTracker(64, time.Minute)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			for j := 0; j < 100; j++ {
				d.observe([]cacheDemandBoundary{{fmt.Sprintf("%d/%d", i, j), 256}}, time.Now())
			}
		}(i)
	}
	wg.Wait()
	if len(d.entries) > 64 || d.order.Len() != len(d.entries) {
		t.Fatal("concurrent capacity/order drift")
	}
}

func TestCacheOpportunityReasons(t *testing.T) {
	cases := []struct {
		o        CacheOpportunity
		selected bool
		want     string
	}{
		{CacheOpportunity{}, false, "not_evaluated"},
		{CacheOpportunity{Evaluated: true}, false, "no_repeat_observed"},
		{CacheOpportunity{Evaluated: true, RepeatedPrefixTokens: 256}, false, "repeat_without_holder"},
		{CacheOpportunity{Evaluated: true, MatchingHolders: 1}, false, "holder_evidence_unusable"},
		{CacheOpportunity{Evaluated: true, MatchingHolders: 1, ValidHolders: 1}, false, "holder_unavailable"},
		{CacheOpportunity{Evaluated: true, MatchingHolders: 1, ValidHolders: 1, UsableCandidates: 1, CreditedCandidates: 1}, false, "holder_not_selected"},
		{CacheOpportunity{Evaluated: true, MatchingHolders: 1, ValidHolders: 1, UsableCandidates: 1}, false, "holder_no_positive_credit"},
		{CacheOpportunity{Evaluated: true, MatchingHolders: 1, ValidHolders: 1, UsableCandidates: 1}, true, "selected"},
	}
	for _, c := range cases {
		p := &PendingRequest{CacheOpportunity: c.o, CacheSelectionSelected: c.selected}
		if got := p.CacheOpportunityReason(); got != c.want {
			t.Fatalf("got %s want %s", got, c.want)
		}
	}
}

func TestCacheDemandOutOfOrderTimestampsCannotReviveExpiredPrefixes(t *testing.T) {
	d := newCacheDemandTracker(4, time.Minute)
	now := time.Unix(1000, 0)
	d.observe([]cacheDemandBoundary{{"newer", 256}}, now)
	d.observe([]cacheDemandBoundary{{"older", 512}}, now.Add(-10*time.Second))
	if repeated, _ := d.observe([]cacheDemandBoundary{{"older", 512}}, now.Add(51*time.Second)); repeated != 0 {
		t.Fatal("expired entry hidden behind a newer entry was treated as repeat demand")
	}
}

// A boundary planned nine minutes ago must still be found while other plans
// arrive at fleet rate. Before the dedicated cap the demand index shared the
// 10,000-entry holder cap and turned over in about a minute against the
// 10-minute TTL, so nearly every real repeat looked novel.
func TestCacheDemandRetainsBoundaryForTTLAtFleetRate(t *testing.T) {
	const fillRatePerSecond, fillMinutes = 200, 9
	fill := func(d *cacheDemandTracker, start time.Time) time.Time {
		step := time.Second / fillRatePerSecond
		now := start
		for i := 0; i < fillRatePerSecond*60*fillMinutes; i++ {
			now = now.Add(step)
			d.observe([]cacheDemandBoundary{{fmt.Sprintf("other/%d", i), 256}}, now)
		}
		return now
	}
	start := time.Unix(1_700_000_000, 0)
	target := []cacheDemandBoundary{{"repeated", 1024}}

	sized := newCacheDemandTracker(cacheDemandMaxEntries, defaultCacheRoutingTTL)
	sized.observe(target, start)
	now := fill(sized, start)
	if got, key := sized.observe(target, now); got != 1024 || key != "repeated" {
		t.Fatalf("boundary observed %s earlier at %d/s was lost: repeat=%d key=%q",
			now.Sub(start), fillRatePerSecond, got, key)
	}
	if sized.order.Len() != len(sized.entries) {
		t.Fatalf("map/order drift: %d vs %d", len(sized.entries), sized.order.Len())
	}

	holderSized := newCacheDemandTracker(cacheRoutingMaxEntries, defaultCacheRoutingTTL)
	holderSized.observe(target, start)
	now = fill(holderSized, start)
	if got, _ := holderSized.observe(target, now); got != 0 {
		t.Fatalf("holder-sized index unexpectedly retained the boundary: %d", got)
	}
}

func TestCacheDemandCapIsIndependentOfHolderCaps(t *testing.T) {
	tracker := newCacheRoutingTracker(defaultCacheRoutingTTL, defaultCacheRoutingMaxHolders)
	if tracker.demand.limit != cacheDemandMaxEntries {
		t.Fatalf("demand cap=%d, want %d", tracker.demand.limit, cacheDemandMaxEntries)
	}
	if tracker.maxEntries != cacheRoutingMaxEntries || tracker.maxAttempts != cacheRoutingMaxAttempts {
		t.Fatalf("holder caps changed: entries=%d attempts=%d", tracker.maxEntries, tracker.maxAttempts)
	}
	if cacheDemandMaxEntries < 300*int(defaultCacheRoutingTTL/time.Second) {
		t.Fatalf("demand cap %d does not hold %s at 300 entries/s", cacheDemandMaxEntries, defaultCacheRoutingTTL)
	}
}

func TestCacheDemandEvictsAtExactlyTheCap(t *testing.T) {
	d := newCacheDemandTracker(cacheDemandMaxEntries, defaultCacheRoutingTTL)
	now := time.Unix(1_700_000_000, 0)
	for i := 0; i <= cacheDemandMaxEntries; i++ {
		d.observe([]cacheDemandBoundary{{fmt.Sprintf("k/%d", i), 256}}, now.Add(time.Duration(i)*time.Microsecond))
	}
	if len(d.entries) != cacheDemandMaxEntries || d.order.Len() != cacheDemandMaxEntries {
		t.Fatalf("entries=%d order=%d, want exactly %d", len(d.entries), d.order.Len(), cacheDemandMaxEntries)
	}
	if _, ok := d.entries["k/0"]; ok {
		t.Fatal("oldest entry survived the cap")
	}
	if _, ok := d.entries["k/1"]; !ok {
		t.Fatal("cap evicted more than one entry")
	}
	if _, ok := d.entries[fmt.Sprintf("k/%d", cacheDemandMaxEntries)]; !ok {
		t.Fatal("newest entry missing")
	}
}

// The plan-path sweep must not drain a whole stale index under the lock. Each
// observe expires a bounded slice from the head; stale entries that remain are
// still never matched, and later calls finish draining.
func TestCacheDemandExpiryIsBoundedPerObserveAndStaleNeverMatches(t *testing.T) {
	const filled = 5 * cacheDemandMaxExpiryPerObserve
	d := newCacheDemandTracker(cacheDemandMaxEntries, defaultCacheRoutingTTL)
	start := time.Unix(1_700_000_000, 0)
	for i := 0; i < filled; i++ {
		d.observe([]cacheDemandBoundary{{fmt.Sprintf("stale/%d", i), 512}}, start.Add(time.Duration(i)*time.Millisecond))
	}
	later := start.Add(defaultCacheRoutingTTL + time.Minute)
	if got, _ := d.observe([]cacheDemandBoundary{{"fresh", 256}}, later); got != 0 {
		t.Fatalf("fresh key matched: %d", got)
	}
	if want := filled - cacheDemandMaxExpiryPerObserve + 1; len(d.entries) != want {
		t.Fatalf("one observe expired %d entries, want exactly %d (bounded)",
			filled+1-len(d.entries), cacheDemandMaxExpiryPerObserve)
	}
	// A stale entry that survived the bounded sweep must not read as demand.
	if got, key := d.observe([]cacheDemandBoundary{{fmt.Sprintf("stale/%d", filled-1), 512}}, later); got != 0 || key != "" {
		t.Fatalf("stale surviving entry matched: %d %q", got, key)
	}
	for i := 0; i < filled/cacheDemandMaxExpiryPerObserve+1; i++ {
		d.observe([]cacheDemandBoundary{{fmt.Sprintf("fresh/%d", i), 256}}, later.Add(time.Duration(i)*time.Millisecond))
	}
	for key := range d.entries {
		if len(key) >= 6 && key[:6] == "stale/" && key != fmt.Sprintf("stale/%d", filled-1) {
			t.Fatalf("stale entry %q survived repeated sweeps", key)
		}
	}
	if d.order.Len() != len(d.entries) {
		t.Fatal("map/order drift after bounded sweeps")
	}
}
