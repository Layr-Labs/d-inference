package registry_test

import (
	"fmt"
	"math/rand"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry/selection"
)

func TestCacheAffinityStableAcrossPoolOrderAndFailsOver(t *testing.T) {
	a := &cacheAffinityCandidate{cacheAffinityEligible: true, provider: &cacheAffinityProvider{ID: "a"}, costMs: 100}
	b := &cacheAffinityCandidate{cacheAffinityEligible: true, provider: &cacheAffinityProvider{ID: "b"}, costMs: 100}
	c := &cacheAffinityCandidate{cacheAffinityEligible: true, provider: &cacheAffinityProvider{ID: "c"}, costMs: 100}
	pool := []*cacheAffinityCandidate{a, b, c}
	winner, _, _, path := selectCacheAffinityFixture(pool, "scoped-prefix")
	if path != cacheAffinityPath {
		t.Fatalf("path %s", fmt.Sprint(path))
	}
	for _, order := range [][]*cacheAffinityCandidate{{c, a, b}, {b, c, a}, pool} {
		got, _, _, _ := selectCacheAffinityFixture(order, "scoped-prefix")
		if got != winner {
			t.Fatal("same prefix moved with pool order")
		}
	}
	winner.firstContent.ServiceMs = 1
	fallback, _, _, _ := selectCacheAffinityFixture(pool, "scoped-prefix")
	if fallback == winner {
		t.Fatal("affinity overrode queue headroom")
	}
	winner.firstContent.ServiceMs = 0
	winner.firstContent.ServiceMs = 2
	fallback, _, _, _ = selectCacheAffinityFixture(pool, "scoped-prefix")
	if fallback == winner {
		t.Fatal("affinity overrode pending load")
	}
	winner.firstContent.ServiceMs = 0
	winner.firstContent.ExpectedMs = 10000
	fallback, _, _, _ = selectCacheAffinityFixture(pool, "scoped-prefix")
	if fallback == winner {
		t.Fatal("affinity overrode service cost")
	}
}

func TestCacheAffinityDoesNotInventCreditOrOverrideVerifiedSavings(t *testing.T) {
	cold := &cacheAffinityCandidate{cacheAffinityEligible: true, provider: &cacheAffinityProvider{ID: "cold"}, costMs: 100}
	cached := &cacheAffinityCandidate{cacheAffinityEligible: true, provider: &cacheAffinityProvider{ID: "cached"}, costMs: 99}
	cached.breakdown.CacheDiscountMs = 20
	cached.firstContent.CachedTokens = 20
	cached.cacheEstimatedTTFTSavedMs = 20
	got, _, _, path := selectCacheAffinityFixture([]*cacheAffinityCandidate{cold, cached}, "scoped-prefix")
	if got != cached || path == cacheAffinityPath {
		t.Fatal("affinity overrode actual cache pricing")
	}
	if cold.breakdown.CacheDiscountMs != 0 || cold.cacheTier != "" {
		t.Fatal("demand manufactured cache evidence")
	}
}

func TestCacheAffinitySeedsOnlyCacheCapableEquivalentCandidates(t *testing.T) {
	incapable := &cacheAffinityCandidate{provider: &cacheAffinityProvider{ID: "legacy"}, costMs: 100}
	capable := &cacheAffinityCandidate{provider: &cacheAffinityProvider{ID: "ready"}, costMs: 100, cacheAffinityEligible: true}
	for i := 0; i < 20; i++ {
		winner, _, _, path := selectCacheAffinityFixture([]*cacheAffinityCandidate{incapable, capable}, "repeat")
		if winner != capable || path != cacheAffinityPath {
			t.Fatal("repeat was seeded on an incapable provider")
		}
	}
	capable.firstContent.ServiceMs = 1
	winner, _, _, path := selectCacheAffinityFixture([]*cacheAffinityCandidate{incapable, capable}, "repeat")
	if winner != incapable || path == cacheAffinityPath {
		t.Fatal("affinity displaced a less loaded candidate")
	}
}

func BenchmarkCacheAffinity(b *testing.B) {
	for _, size := range []int{32, 350, 1000} {
		for _, enabled := range []bool{false, true} {
			b.Run(fmt.Sprintf("providers=%d/affinity=%t", size, enabled), func(b *testing.B) {
				pool := make([]*cacheAffinityCandidate, size)
				for i := range pool {
					pool[i] = &cacheAffinityCandidate{provider: &cacheAffinityProvider{ID: fmt.Sprint(i)}, costMs: 100, cacheAffinityEligible: true}
				}
				key := ""
				if enabled {
					key = "private-tenant-build-bound-prefix"
				}
				b.ReportAllocs()
				b.ResetTimer()
				for i := 0; i < b.N; i++ {
					selectCacheAffinityFixture(pool, key)
				}
			})
		}
	}
}

const cacheAffinityPath = selection.PrefixAffinity

type cacheAffinityProvider struct{ ID string }
type cacheAffinityCandidate struct {
	provider                                               *cacheAffinityProvider
	firstContent                                           struct{ ExpectedMs, ServiceMs, CachedTokens float64 }
	breakdown                                              struct{ CacheDiscountMs, HealthMs, CapacityRateMs float64 }
	costMs, cacheEstimatedTTFTSavedMs, cacheEvidenceWeight float64
	cacheAffinityEligible                                  bool
	cacheTier                                              string
}

// The fixture supplies the same detached inputs and RNG to the actual selector;
// indices are mapped back to fixture identity, without implementing ranking.
func selectCacheAffinityFixture(pool []*cacheAffinityCandidate, affinity string) (winner, runnerUp *cacheAffinityCandidate, near int, path selection.Path) {
	decision := selection.Select(pool, func(c *cacheAffinityCandidate) selection.Candidate {
		id := ""
		if c.provider != nil {
			id = c.provider.ID
		}
		return selection.Candidate{ProviderID: id, ExpectedMs: c.firstContent.ExpectedMs,
			HealthMs: c.breakdown.HealthMs, CapacityRateMs: c.breakdown.CapacityRateMs,
			ServiceMs: c.firstContent.ServiceMs, CachedTokens: c.firstContent.CachedTokens,
			CacheSavedMs: c.cacheEstimatedTTFTSavedMs, CacheEvidenceWeight: c.cacheEvidenceWeight,
			AffinityEligible: c.cacheAffinityEligible}
	}, rand.Intn, affinity)
	if decision.Winner >= 0 {
		winner = pool[decision.Winner]
	}
	if decision.RunnerUp >= 0 {
		runnerUp = pool[decision.RunnerUp]
	}
	return winner, runnerUp, decision.NearTieSize, decision.Path
}
