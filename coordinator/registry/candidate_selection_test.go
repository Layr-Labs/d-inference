package registry

import (
	"fmt"
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

// The policy oracle lives in selection; this verifies the registry projection
// retains first-content inputs and does not substitute legacy total cost.
func TestSelectRoutingCandidateProjection(t *testing.T) {
	a, b := mkCandidate("a", 100, 0, 0, 0), mkCandidate("b", 201, 0, 0, 0)
	a.costMs, b.costMs = 100000, 1
	pool := []*routingCandidate{a, b}
	winner, runner, near, path := selectRoutingCandidate(pool)
	if winner != a || runner != b || near != 1 || path != SelectionUniqueMin {
		t.Fatal("projection substituted legacy cost for first-content ranking")
	}
	a.breakdown.HealthMs = 202
	winner, runner, near, path = selectRoutingCandidate(pool)
	if winner != b || runner != a || near != 1 || path != SelectionUniqueMin || !slices.Equal(pool, []*routingCandidate{a, b}) {
		t.Fatal("projection lost health penalty or changed the pool")
	}
}
