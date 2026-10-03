package selection

import (
	"fmt"
	"math/rand"
	"slices"
	"testing"
)

// Moved from the registry selector tests: the oracle sorts and filters
// independently, checking every allowed winner rather than one random draw.
func TestMatchesRankingPolicy(t *testing.T) {
	rng := rand.New(rand.NewSource(82427))
	for trial := 0; trial < 2000; trial++ {
		pool := make([]Candidate, 1+rng.Intn(25))
		indices := make([]int, len(pool))
		for i := range pool {
			discount := float64(rng.Intn(4) * 100)
			pool[i] = Candidate{
				ProviderID: fmt.Sprint(i), ExpectedMs: float64(rng.Intn(20) * 25),
				ServiceMs:    float64(rng.Intn(4)*1000 + rng.Intn(4)),
				CachedTokens: discount, CacheSavedMs: discount,
				CacheEvidenceWeight: float64(1+rng.Intn(4)) / 4,
				HealthMs:            float64(rng.Intn(3) * 50), CapacityRateMs: float64(rng.Intn(3) * 50),
			}
			indices[i] = i
		}
		original := slices.Clone(pool)
		rank := func(i int) float64 { c := pool[i]; return c.ExpectedMs + c.HealthMs + c.CapacityRateMs }
		slices.SortStableFunc(indices, func(a, b int) int {
			if rank(a) < rank(b) {
				return -1
			}
			if rank(a) > rank(b) {
				return 1
			}
			return 0
		})
		near := slices.DeleteFunc(slices.Clone(indices), func(i int) bool { return rank(i) > rank(indices[0])+100 })
		leastWork := pool[near[0]].ServiceMs
		for _, i := range near {
			leastWork = min(leastWork, pool[i].ServiceMs)
		}
		choices := slices.DeleteFunc(slices.Clone(near), func(i int) bool { return pool[i].ServiceMs != leastWork })
		credited := slices.DeleteFunc(slices.Clone(choices), func(i int) bool { return pool[i].CachedTokens <= 0 || pool[i].CacheSavedMs <= 0 })
		if len(credited) > 0 {
			weight := 0.0
			for _, i := range credited {
				weight = max(weight, pool[i].CacheEvidenceWeight)
			}
			choices = slices.DeleteFunc(credited, func(i int) bool { return pool[i].CacheEvidenceWeight != weight })
		}
		ranking := Rank(pool)
		if ranking.Choices != len(choices) {
			t.Fatalf("trial %d: choices %d, want %d", trial, ranking.Choices, len(choices))
		}
		seen := make(map[int]bool)
		for draw := 0; draw < ranking.Choices; draw++ {
			decision := ranking.Choose(pool, draw, "")
			if !slices.Contains(choices, decision.Winner) || decision.NearTieSize != len(near) || seen[decision.Winner] {
				t.Fatalf("trial %d: invalid decision %+v", trial, decision)
			}
			seen[decision.Winner] = true
			expectedRunner := -1
			for _, i := range indices {
				if i != decision.Winner {
					expectedRunner = i
					break
				}
			}
			if decision.RunnerUp != expectedRunner || !slices.Equal(pool, original) {
				t.Fatalf("trial %d: wrong runner-up or mutated pool", trial)
			}
		}
	}
}

func TestSelectionPathsAndFastBandBoundary(t *testing.T) {
	for _, tc := range []struct {
		name     string
		pool     []Candidate
		draw     int
		affinity string
		want     Decision
	}{
		{"empty", nil, 0, "", Decision{-1, -1, 0, None}},
		{"unique", []Candidate{{ExpectedMs: 100}, {ExpectedMs: 201}}, 0, "", Decision{0, 1, 1, UniqueMin}},
		{"inclusive_band", []Candidate{{ExpectedMs: 100, ServiceMs: 10}, {ExpectedMs: 200}}, 0, "", Decision{1, 0, 2, TiePending}},
		{"uniform_draw", []Candidate{{}, {}}, 1, "", Decision{1, 0, 2, Random}},
		{"credit", []Candidate{{}, {CachedTokens: 1, CacheSavedMs: 1}}, 0, "", Decision{1, 0, 2, CacheCredit}},
		{"nonpositive_saving", []Candidate{{}, {CachedTokens: 1, CacheSavedMs: -1}}, 0, "", Decision{0, 1, 2, Random}},
		{"one_affinity_capable", []Candidate{{}, {AffinityEligible: true}}, 0, "key", Decision{1, 0, 2, PrefixAffinity}},
		{"no_affinity_capable", []Candidate{{}, {}}, 0, "key", Decision{0, 1, 2, Random}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := Rank(tc.pool).Choose(tc.pool, tc.draw, tc.affinity); got != tc.want {
				t.Fatalf("got %+v, want %+v", got, tc.want)
			}
		})
	}
}

func TestAffinityStableAndSubordinateToWork(t *testing.T) {
	pool := []Candidate{{ProviderID: "a", AffinityEligible: true}, {ProviderID: "bb", AffinityEligible: true}, {ProviderID: "ccc", AffinityEligible: true}}
	decision := Rank(pool).Choose(pool, 0, "scoped-prefix")
	winner := pool[decision.Winner].ProviderID
	slices.Reverse(pool)
	for draw := range len(pool) {
		got := Rank(pool).Choose(pool, draw, "scoped-prefix")
		if got.Path != PrefixAffinity || pool[got.Winner].ProviderID != winner {
			t.Fatal("affinity changed with order or draw")
		}
	}
	for i := range pool {
		if pool[i].ProviderID == winner {
			pool[i].ServiceMs = 1
		}
	}
	got := Rank(pool).Choose(pool, 0, "scoped-prefix")
	if pool[got.Winner].ProviderID == winner {
		t.Fatal("affinity overrode service work")
	}
}
