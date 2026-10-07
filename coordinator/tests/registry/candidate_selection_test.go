package registry_test

import (
	"fmt"
	"math/rand"
	"slices"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/registry/selection"
)

type selectionTestCandidate struct {
	id                        string
	firstContent              forecast.Estimate
	breakdown                 cachepolicy.ServiceBreakdown
	cacheEstimatedTTFTSavedMs float64
	cacheEvidenceWeight       float64
	cacheAffinityEligible     bool
}

func makeSelectionTestCandidate(id string, cost float64, queue, pending int, discount float64) *selectionTestCandidate {
	return &selectionTestCandidate{
		id:                        id,
		firstContent:              forecast.Estimate{Status: forecast.Unknown, ExpectedMs: cost, ServiceMs: float64(queue+pending) * 1000, CachedTokens: discount},
		cacheEstimatedTTFTSavedMs: discount,
		breakdown:                 cachepolicy.ServiceBreakdown{CacheDiscountMs: discount, Total: cost},
	}
}

func projectSelectionTestCandidate(c *selectionTestCandidate) selection.Candidate {
	return selection.Project(c.id, &c.firstContent, &c.breakdown, c.cacheEstimatedTTFTSavedMs, c.cacheEvidenceWeight, c.cacheAffinityEligible)
}

func TestRoutingPreferencesPreserveFallbackAndOrder(t *testing.T) {
	a, b, c := makeSelectionTestCandidate("a", 1000, 0, 0, 0), makeSelectionTestCandidate("b", 1000, 0, 0, 0), makeSelectionTestCandidate("c", 1000, 0, 0, 0)
	pool := []*selectionTestCandidate{a, b, c}
	pool = selection.Prefer(pool, func(c *selectionTestCandidate) bool { return false })
	if !slices.Equal(pool, []*selectionTestCandidate{a, b, c}) {
		t.Fatal("an unmatched preference discarded or reordered candidates")
	}
	pool = selection.Prefer(pool, func(c *selectionTestCandidate) bool { return c != b })
	pool = selection.Prefer(pool, func(c *selectionTestCandidate) bool { return false })
	if !slices.Equal(pool, []*selectionTestCandidate{a, c}) {
		t.Fatal("a subsequent preference lost the earlier preference or changed order")
	}
	pool = selection.Prefer(pool, func(candidate *selectionTestCandidate) bool { return candidate == c })
	if !slices.Equal(pool, []*selectionTestCandidate{c}) {
		t.Fatal("successive preferences did not narrow to the remaining match")
	}
}

func BenchmarkSelectRoutingCandidate(b *testing.B) {
	for _, size := range []int{1, 32, 350} {
		for _, cached := range []bool{false, true} {
			b.Run(fmt.Sprintf("providers=%d/cache=%t", size, cached), func(b *testing.B) {
				pool := make([]*selectionTestCandidate, size)
				for i := range pool {
					discount := 0.0
					if cached && i%3 == 0 {
						discount = 500
					}
					pool[i] = makeSelectionTestCandidate(fmt.Sprint(i), float64(1000+i%11*100), i%3, i%5, discount)
				}
				b.ReportAllocs()
				b.ResetTimer()
				for i := 0; i < b.N; i++ {
					selection.Select(pool, projectSelectionTestCandidate, rand.Intn, "")
				}
			})
		}
	}
}

// Exercise the production projection, independently varying its legacy total
// cost and first-content forecast to ensure they cannot be substituted.
func TestSelectRoutingCandidateProjection(t *testing.T) {
	a, b := makeSelectionTestCandidate("a", 100, 0, 0, 0), makeSelectionTestCandidate("b", 201, 0, 0, 0)
	a.breakdown.Total, b.breakdown.Total = 100000, 1
	pool := []*selectionTestCandidate{a, b}
	decision := selection.Select(pool, projectSelectionTestCandidate, rand.Intn, "")
	if decision.Winner < 0 || decision.RunnerUp < 0 || pool[decision.Winner] != a || pool[decision.RunnerUp] != b || decision.NearTieSize != 1 || decision.Path != selection.UniqueMin {
		t.Fatal("projection substituted legacy cost for first-content ranking")
	}
	a.breakdown.HealthMs = 202
	decision = selection.Select(pool, projectSelectionTestCandidate, rand.Intn, "")
	if decision.Winner < 0 || decision.RunnerUp < 0 || pool[decision.Winner] != b || pool[decision.RunnerUp] != a || decision.NearTieSize != 1 || decision.Path != selection.UniqueMin || !slices.Equal(pool, []*selectionTestCandidate{a, b}) {
		t.Fatal("projection lost health penalty or changed the pool")
	}
}
