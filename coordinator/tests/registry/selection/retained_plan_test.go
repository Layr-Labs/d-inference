package selection_test

import (
	"fmt"
	production "github.com/eigeninference/d-inference/coordinator/registry/selection"
	"math/rand"
	"reflect"
	"testing"
)

func TestRetainRankedMatchesSequentialSelection(t *testing.T) {
	cases := 0
	for seed := int64(0); seed < 48; seed++ {
		for _, n := range []int{0, 1, 2, 3, 32, 350, 512, 513, 769} {
			for _, affinity := range []string{"", "stable-affinity"} {
				rng := rand.New(rand.NewSource(seed*1009 + int64(n)))
				pool := make([]int, n)
				views := make([]production.Candidate, n)
				for i := range pool {
					pool[i] = i
					views[i] = production.Candidate{ProviderID: fmt.Sprintf("p-%04d", i), ExpectedMs: float64(rng.Intn(9) * 35), HealthMs: float64(rng.Intn(3) * 7), CapacityRateMs: float64(rng.Intn(3) * 9), ServiceMs: float64(rng.Intn(3)), AffinityEligible: rng.Intn(2) == 0}
					if rng.Intn(2) == 0 {
						views[i].CachedTokens = 100
						views[i].CacheSavedMs = 20
						views[i].CacheEvidenceWeight = float64(rng.Intn(3)) / 2
					}
				}
				original := append([]int(nil), pool...)
				winner := -1
				if n > 0 {
					winner = rng.Intn(n)
				}
				a, b := rand.New(rand.NewSource(seed)), rand.New(rand.NewSource(seed))
				var drawsA, drawsB []int
				drawA := func(k int) int { drawsA = append(drawsA, k); return a.Intn(k) }
				drawB := func(k int) int { drawsB = append(drawsB, k); return b.Intn(k) }
				project := func(i int) production.Candidate { return views[i] }
				retain := func(i int) int { return i }
				var want []int
				selected := map[int]bool{winner: true}
				for len(want) < 8 {
					var available []int
					for _, candidate := range pool {
						if !selected[candidate] {
							available = append(available, candidate)
						}
					}
					if len(available) == 0 {
						break
					}
					decision := production.Select(available, project, drawA, affinity)
					chosen := available[decision.Winner]
					want = append(want, chosen)
					selected[chosen] = true
				}
				if want == nil {
					want = []int{}
				}
				got := production.RetainRanked(pool, winner, 8, project, drawB, affinity, retain)
				if !reflect.DeepEqual(got, want) || !reflect.DeepEqual(drawsA, drawsB) {
					t.Fatalf("seed=%d n=%d affinity=%q got=%v want=%v draws=%v/%v", seed, n, affinity, got, want, drawsB, drawsA)
				}
				if !reflect.DeepEqual(pool, original) && n != 0 {
					t.Fatal("mutated original pool")
				}
				cases++
			}
		}
	}
	t.Logf("retained-plan differential cases=%d", cases)
}
