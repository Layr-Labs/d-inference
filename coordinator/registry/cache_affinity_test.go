package registry

import (
	"fmt"
	"testing"
)

func TestCacheAffinityStableAcrossPoolOrderAndFailsOver(t *testing.T) {
	a := &routingCandidate{cacheAffinityEligible: true, provider: &Provider{ID: "a"}, costMs: 100}
	b := &routingCandidate{cacheAffinityEligible: true, provider: &Provider{ID: "b"}, costMs: 100}
	c := &routingCandidate{cacheAffinityEligible: true, provider: &Provider{ID: "c"}, costMs: 100}
	pool := []*routingCandidate{a, b, c}
	winner, _, _, path := selectRoutingCandidateWithAffinity(pool, "scoped-prefix")
	if path != SelectionPrefixAffinity {
		t.Fatalf("path %s", path)
	}
	for _, order := range [][]*routingCandidate{{c, a, b}, {b, c, a}, pool} {
		got, _, _, _ := selectRoutingCandidateWithAffinity(order, "scoped-prefix")
		if got != winner {
			t.Fatal("same prefix moved with pool order")
		}
	}
	winner.effectiveQueue = 1
	fallback, _, _, _ := selectRoutingCandidateWithAffinity(pool, "scoped-prefix")
	if fallback == winner {
		t.Fatal("affinity overrode queue headroom")
	}
	winner.effectiveQueue = 0
	winner.snapshot.TotalPending = 1
	fallback, _, _, _ = selectRoutingCandidateWithAffinity(pool, "scoped-prefix")
	if fallback == winner {
		t.Fatal("affinity overrode pending load")
	}
	winner.snapshot.TotalPending = 0
	winner.costMs = 10000
	fallback, _, _, _ = selectRoutingCandidateWithAffinity(pool, "scoped-prefix")
	if fallback == winner {
		t.Fatal("affinity overrode service cost")
	}
}

func TestCacheAffinityDoesNotInventCreditOrOverrideVerifiedSavings(t *testing.T) {
	cold := &routingCandidate{cacheAffinityEligible: true, provider: &Provider{ID: "cold"}, costMs: 100}
	cached := &routingCandidate{cacheAffinityEligible: true, provider: &Provider{ID: "cached"}, costMs: 99}
	cached.breakdown.CacheDiscountMs = 20
	got, _, _, path := selectRoutingCandidateWithAffinity([]*routingCandidate{cold, cached}, "scoped-prefix")
	if got != cached || path == SelectionPrefixAffinity {
		t.Fatal("affinity overrode actual cache pricing")
	}
	if cold.breakdown.CacheDiscountMs != 0 || cold.cacheTier != "" {
		t.Fatal("demand manufactured cache evidence")
	}
}

func TestCacheAffinitySeedsOnlyCacheCapableEquivalentCandidates(t *testing.T) {
	incapable := &routingCandidate{provider: &Provider{ID: "legacy"}, costMs: 100}
	capable := &routingCandidate{provider: &Provider{ID: "ready"}, costMs: 100, cacheAffinityEligible: true}
	for i := 0; i < 20; i++ {
		winner, _, _, path := selectRoutingCandidateWithAffinity([]*routingCandidate{incapable, capable}, "repeat")
		if winner != capable || path != SelectionPrefixAffinity {
			t.Fatal("repeat was seeded on an incapable provider")
		}
	}
	capable.effectiveQueue = 1
	winner, _, _, path := selectRoutingCandidateWithAffinity([]*routingCandidate{incapable, capable}, "repeat")
	if winner != incapable || path == SelectionPrefixAffinity {
		t.Fatal("affinity displaced a less loaded candidate")
	}
}

func BenchmarkCacheAffinity(b *testing.B) {
	for _, size := range []int{32, 350, 1000} {
		for _, enabled := range []bool{false, true} {
			b.Run(fmt.Sprintf("providers=%d/affinity=%t", size, enabled), func(b *testing.B) {
				pool := make([]*routingCandidate, size)
				for i := range pool {
					pool[i] = &routingCandidate{provider: &Provider{ID: fmt.Sprint(i)}, costMs: 100, cacheAffinityEligible: true}
				}
				key := ""
				if enabled {
					key = "private-tenant-build-bound-prefix"
				}
				b.ReportAllocs()
				b.ResetTimer()
				for i := 0; i < b.N; i++ {
					selectRoutingCandidateWithAffinity(pool, key)
				}
			})
		}
	}
}
