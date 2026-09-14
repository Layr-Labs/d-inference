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
