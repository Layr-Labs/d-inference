package registry

import (
	"fmt"
	"math/rand"
	"slices"
	"testing"
)

func TestRoutingPreferencesPreserveFallbackAndOrder(t *testing.T) {
	a, b, c := mkCandidate("a", 1000, 0, 0, 0), mkCandidate("b", 1000, 0, 0, 0), mkCandidate("c", 1000, 0, 0, 0)
	pool := []*routingCandidate{a, b, c}
	pool = preferRoutingCandidates(pool, func(c *routingCandidate) bool { return false })
	if !slices.Equal(pool, []*routingCandidate{a, b, c}) {
		t.Fatal("an unmatched preference discarded or reordered candidates")
	}
	pool = preferRoutingCandidates(pool, func(c *routingCandidate) bool { return c != b })
	pool = preferRoutingCandidates(pool, func(c *routingCandidate) bool { return false })
	if !slices.Equal(pool, []*routingCandidate{a, c}) {
		t.Fatal("a subsequent preference lost the earlier preference or changed order")
	}
	pool = preferRoutingCandidates(pool, func(candidate *routingCandidate) bool { return candidate == c })
	if !slices.Equal(pool, []*routingCandidate{c}) {
		t.Fatal("successive preferences did not narrow to the remaining match")
	}
}

func BenchmarkSelectRoutingCandidate(b *testing.B) {
	for _, size := range []int{1, 32, 350} {
		for _, cached := range []bool{false, true} {
			b.Run(fmt.Sprintf("providers=%d/cache=%t", size, cached), func(b *testing.B) {
				pool := make([]*routingCandidate, size)
				for i := range pool {
					discount := 0.0
					if cached && i%3 == 0 {
						discount = 500
					}
					pool[i] = mkCandidate(fmt.Sprint(i), float64(1000+i%11*100), i%3, i%5, discount)
				}
				b.ReportAllocs()
				b.ResetTimer()
				for i := 0; i < b.N; i++ {
					selectRoutingCandidate(pool)
				}
			})
		}
	}
}

// The oracle sorts and filters independently of the production selector. Check
// every permitted winner rather than requiring a particular random draw.
func TestSelectRoutingCandidateMatchesRankingPolicy(t *testing.T) {
	rng := rand.New(rand.NewSource(82427))
	for trial := 0; trial < 1000; trial++ {
		pool := make([]*routingCandidate, 1+rng.Intn(25))
		for i := range pool {
			discount := 0.0
			if rng.Intn(4) == 0 {
				discount = 500
			}
			pool[i] = mkCandidate(fmt.Sprint(i), float64(rng.Intn(20)*500), rng.Intn(4), rng.Intn(4), discount)
		}
		original := slices.Clone(pool)
		near := slices.Clone(pool)
		slices.SortStableFunc(near, func(a, b *routingCandidate) int {
			if a.costMs < b.costMs {
				return -1
			}
			if a.costMs > b.costMs {
				return 1
			}
			return 0
		})
		minimum := near[0].costMs
		window := nearTieCostWindowMs
		if slices.ContainsFunc(pool, func(c *routingCandidate) bool { return c.breakdown.CacheDiscountMs > 0 }) {
			window = 0
		}
		near = slices.DeleteFunc(near, func(c *routingCandidate) bool {
			return c.costMs > minimum+window
		})
		slices.SortStableFunc(near, func(a, b *routingCandidate) int {
			if a.effectiveQueue != b.effectiveQueue {
				return a.effectiveQueue - b.effectiveQueue
			}
			return a.snapshot.totalPending - b.snapshot.totalPending
		})
		equivalent := slices.Clone(near)
		queue, pending := near[0].effectiveQueue, near[0].snapshot.totalPending
		equivalent = slices.DeleteFunc(equivalent, func(c *routingCandidate) bool {
			return c.effectiveQueue != queue || c.snapshot.totalPending != pending
		})
		choices := equivalent
		wantPath := SelectionUniqueMin
		switch {
		case len(choices) > 1:
			wantPath = SelectionRandom
		case len(near) > 1:
			wantPath = SelectionTieQueue
			if slices.ContainsFunc(near, func(c *routingCandidate) bool { return c != choices[0] && c.effectiveQueue == queue }) {
				wantPath = SelectionTiePending
			}
		}
		winner, runnerUp, nearSize, path := selectRoutingCandidate(pool)
		if !slices.Contains(choices, winner) || nearSize != len(near) || path != wantPath {
			t.Fatalf("trial %d: winner=%v near=%d path=%s; want one of %v near=%d path=%s", trial, winner, nearSize, path, choices, len(near), wantPath)
		}
		var wantRunnerUp *routingCandidate
		for _, c := range pool {
			if c != winner && (wantRunnerUp == nil || c.costMs < wantRunnerUp.costMs) {
				wantRunnerUp = c
			}
		}
		if runnerUp != wantRunnerUp || !slices.Equal(pool, original) {
			t.Fatalf("trial %d: incorrect runner-up or mutated candidate pool", trial)
		}
	}
}
