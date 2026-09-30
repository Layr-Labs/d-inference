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
	for trial := 0; trial < 2000; trial++ {
		pool := make([]*routingCandidate, 1+rng.Intn(25))
		for i := range pool {
			discount := float64(rng.Intn(4) * 100)
			pool[i] = mkCandidate(fmt.Sprint(i), float64(rng.Intn(20)*25), rng.Intn(4), rng.Intn(4), discount)
			pool[i].cacheEvidenceWeight = float64(1+rng.Intn(4)) / 4
			// Legacy generation/max-token costs must never become the primary
			// ranking quantity again.
			pool[i].costMs = float64(rng.Intn(100000))
		}
		original := slices.Clone(pool)
		ordered := slices.Clone(pool)
		slices.SortStableFunc(ordered, func(a, b *routingCandidate) int {
			if a.firstContent.ExpectedMs < b.firstContent.ExpectedMs {
				return -1
			}
			if a.firstContent.ExpectedMs > b.firstContent.ExpectedMs {
				return 1
			}
			return 0
		})
		near := slices.DeleteFunc(slices.Clone(ordered), func(c *routingCandidate) bool {
			return c.firstContent.ExpectedMs > ordered[0].firstContent.ExpectedMs+100
		})
		leastWork := near[0].firstContent.ServiceMs
		for _, c := range near {
			leastWork = min(leastWork, c.firstContent.ServiceMs)
		}
		choices := slices.DeleteFunc(slices.Clone(near), func(c *routingCandidate) bool { return c.firstContent.ServiceMs != leastWork })
		credited := slices.DeleteFunc(slices.Clone(choices), func(c *routingCandidate) bool { return c.firstContent.CachedTokens <= 0 })
		if len(credited) > 0 {
			weight := 0.0
			for _, c := range credited {
				weight = max(weight, c.cacheEvidenceWeight)
			}
			choices = slices.DeleteFunc(credited, func(c *routingCandidate) bool { return c.cacheEvidenceWeight != weight })
		}
		winner, runnerUp, nearSize, _ := selectRoutingCandidate(pool)
		if !slices.Contains(choices, winner) || nearSize != len(near) {
			t.Fatalf("trial %d: winner outside allowed fast/work/affinity set", trial)
		}
		var expectedRunner *routingCandidate
		for _, c := range ordered {
			if c != winner {
				expectedRunner = c
				break
			}
		}
		if runnerUp != expectedRunner || !slices.Equal(pool, original) {
			t.Fatalf("trial %d: wrong runner-up or mutated pool", trial)
		}
	}
}
