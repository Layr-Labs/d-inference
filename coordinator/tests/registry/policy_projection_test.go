package registry_test

import (
	"fmt"
	"math/rand"
	"slices"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/memorypolicy"
	"github.com/eigeninference/d-inference/coordinator/registry/selection"
)

func TestFreeMemoryAdmitsTokenBudget(t *testing.T) {
	snap := memorypolicy.Input{
		ActiveTokenBudgetUsed: 28_000,
		ActiveTokenBudgetMax:  32_768,
		ModelSizeGB:           8,
		TotalMemoryGB:         64,
	}
	if !memorypolicy.Admits(memoryInputPtr(snap), 500, 4096) {
		t.Fatal("should admit: 28000 + 4596 = 32596 <= 32768")
	}
	if memorypolicy.Admits(memoryInputPtr(snap), 500, 4500) {
		t.Fatal("should reject: 28000 + 5000 = 33000 > 32768")
	}
}

func TestFreeMemoryAdmitsIncludesQueuedBudget(t *testing.T) {
	snap := memorypolicy.Input{
		ActiveTokenBudgetUsed: 20_000,
		ActiveTokenBudgetMax:  32_768,
		QueuedTokenBudget:     10_000,
		ModelSizeGB:           8,
		TotalMemoryGB:         64,
	}
	if memorypolicy.Admits(memoryInputPtr(snap), 500, 4096) {
		t.Fatal("should reject: active + queued + request exceeds budget")
	}
	snap.QueuedTokenBudget = 0
	if !memorypolicy.Admits(memoryInputPtr(snap), 500, 4096) {
		t.Fatal("should admit when queued budget is zero")
	}
}

// Keep the independent oracle at the production projection boundary as well as leaf tests.
func TestSelectRoutingCandidateMatchesRankingPolicy(t *testing.T) {
	// Retain the unrelated legacy cost input: ranking must use the forecast instead.
	type routingCandidate struct {
		*selectionTestCandidate
		costMs float64
	}
	rng := rand.New(rand.NewSource(82427))
	for trial := 0; trial < 2000; trial++ {
		pool := make([]*routingCandidate, 1+rng.Intn(25))
		for i := range pool {
			discount := float64(rng.Intn(4) * 100)
			pool[i] = &routingCandidate{selectionTestCandidate: makeSelectionTestCandidate(fmt.Sprint(i), float64(rng.Intn(20)*25), rng.Intn(4), rng.Intn(4), discount)}
			pool[i].cacheEvidenceWeight = float64(1+rng.Intn(4)) / 4
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
		decision := selection.Select(pool, func(c *routingCandidate) selection.Candidate {
			return projectSelectionTestCandidate(c.selectionTestCandidate)
		}, rand.Intn, "")
		var winner, runnerUp *routingCandidate
		if decision.Winner >= 0 {
			winner = pool[decision.Winner]
		}
		if decision.RunnerUp >= 0 {
			runnerUp = pool[decision.RunnerUp]
		}
		nearSize := decision.NearTieSize
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
