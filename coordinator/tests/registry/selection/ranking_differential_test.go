package selection_test

import (
	"crypto/sha256"
	"fmt"
	"math"
	"math/rand"
	"strings"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/registry/selection"
)

// Review-only harness: execute the public policy on identical deterministic
// inputs in base and head. The digest records decisions, not a copied policy.
func TestRankingDifferential(t *testing.T) {
	rng := rand.New(rand.NewSource(134082427))
	resultHash := sha256.New()
	cases, decisions, zeroChoices := 0, 0, 0
	poolDigest := func(pool []production.Candidate) [32]byte {
		h := sha256.New()
		for _, c := range pool {
			fmt.Fprintf(h, "%q/%x/%x/%x/%x/%x/%x/%x/%t;", c.ProviderID,
				math.Float64bits(c.ExpectedMs), math.Float64bits(c.HealthMs),
				math.Float64bits(c.CapacityRateMs), math.Float64bits(c.ServiceMs),
				math.Float64bits(c.CachedTokens), math.Float64bits(c.CacheSavedMs),
				math.Float64bits(c.CacheEvidenceWeight), c.AffinityEligible)
		}
		var out [32]byte
		copy(out[:], h.Sum(nil))
		return out
	}
	run := func(label string, pool []production.Candidate, checkSelect bool) {
		cases++
		before := poolDigest(pool)
		ranking := production.Rank(pool)
		fmt.Fprintf(resultHash, "%q/%d/%d/%d;", label, len(pool), ranking.NearTieSize, ranking.Choices)
		if len(pool) > 0 && ranking.Choices == 0 {
			// Non-finite evidence may have no valid draw. Record this outcome
			// without violating Choose's documented nonempty-pool draw contract.
			zeroChoices++
		} else {
			draws := ranking.Choices
			if len(pool) == 0 {
				draws = 1
			}
			for _, affinity := range []string{"", "review-affinity-fixed-key"} {
				for draw := 0; draw < draws; draw++ {
					decision := ranking.Choose(pool, draw, affinity)
					decisions++
					fmt.Fprintf(resultHash, "%q/%d/%d/%d/%d/%d;", affinity, draw,
						decision.Winner, decision.RunnerUp, decision.NearTieSize, decision.Path)
					if checkSelect {
						calls := 0
						got := production.Select(pool, func(c production.Candidate) production.Candidate { return c },
							func(n int) int {
								calls++
								if n != ranking.Choices {
									t.Fatalf("%s: Select offered %d choices, Rank offered %d", label, n, ranking.Choices)
								}
								return draw
							}, affinity)
						if got != decision || (len(pool) == 0 && calls != 0) || (len(pool) > 0 && calls != 1) {
							t.Fatalf("%s: Select=%+v Choose=%+v draw calls=%d", label, got, decision, calls)
						}
					}
				}
			}
		}
		if after := poolDigest(pool); after != before {
			t.Fatalf("%s: Rank/Choose/Select mutated input candidates", label)
		}
	}

	// Hit stack/spill projection boundaries as well as realistic fleet sizes.
	for _, n := range []int{0, 1, 2, 3, 32, 350, 512, 513, 769} {
		for mode := 0; mode < 4; mode++ {
			pool := make([]production.Candidate, n)
			for i := range pool {
				c := production.Candidate{ProviderID: fmt.Sprintf("provider-%04d-%s", i, strings.Repeat("x", i%7)), AffinityEligible: i%3 != 0}
				switch mode {
				case 0: // Entire pool ties; traverse every uniform draw.
					c.ExpectedMs, c.ServiceMs = 100, 1000
				case 1: // Cache-credit ties and varying provider-ID lengths.
					c.ExpectedMs, c.ServiceMs = 100, 1000
					if i%2 == 0 {
						c.CachedTokens, c.CacheSavedMs = 100, 30
						c.CacheEvidenceWeight = float64(1+i%4) / 4
					}
				case 2: // Inclusive 100 ms boundary and separate health cost.
					c.ExpectedMs = float64(i%4) * 50
					c.HealthMs = float64(i%3) * 25
					c.CapacityRateMs = float64(i%2) * 25
					c.ServiceMs = float64(i % 5)
				case 3: // Deterministic finite random fleet.
					c.ExpectedMs = float64(rng.Intn(20) * 25)
					c.HealthMs, c.CapacityRateMs = float64(rng.Intn(3)*50), float64(rng.Intn(3)*50)
					c.ServiceMs = float64(rng.Intn(4)*1000 + rng.Intn(4))
					c.CachedTokens, c.CacheSavedMs = float64(rng.Intn(4)*100), float64(rng.Intn(4)*100)
					c.CacheEvidenceWeight = float64(1+rng.Intn(4)) / 4
				}
				pool[i] = c
			}
			run(fmt.Sprintf("boundary/n=%d/mode=%d", n, mode), pool, true)
		}
	}

	// Random finite and malformed floating-point pools exercise exactly the
	// same exported contract on both revisions, including exceptional ordering.
	special := []float64{math.NaN(), math.Inf(1), math.Inf(-1), math.Copysign(0, -1), 0, 100}
	for trial := 0; trial < 2048; trial++ {
		pool := make([]production.Candidate, 1+rng.Intn(80))
		for i := range pool {
			pool[i] = production.Candidate{
				ProviderID: fmt.Sprintf("random-%d-%d", trial, i), ExpectedMs: float64(rng.Intn(20) * 25),
				HealthMs: float64(rng.Intn(3) * 50), CapacityRateMs: float64(rng.Intn(3) * 50),
				ServiceMs: float64(rng.Intn(4)*1000 + rng.Intn(4)), CachedTokens: float64(rng.Intn(4) * 100),
				CacheSavedMs: float64(rng.Intn(4) * 100), CacheEvidenceWeight: float64(1+rng.Intn(4)) / 4,
				AffinityEligible: rng.Intn(2) == 0,
			}
		}
		if trial%3 == 0 {
			i, value := rng.Intn(len(pool)), special[(trial/3)%len(special)]
			switch (trial / 3 / len(special)) % 7 {
			case 0:
				pool[i].ExpectedMs = value
			case 1:
				pool[i].HealthMs = value
			case 2:
				pool[i].CapacityRateMs = value
			case 3:
				pool[i].ServiceMs = value
			case 4:
				pool[i].CachedTokens = value
			case 5:
				pool[i].CacheSavedMs = value
			case 6:
				pool[i].CacheEvidenceWeight = value
			}
		}
		run(fmt.Sprintf("random/%d", trial), pool, false)
	}
	for _, value := range special {
		for _, first := range []bool{false, true} {
			pool := []production.Candidate{{ProviderID: "finite", ExpectedMs: 100}, {ProviderID: "exceptional", ExpectedMs: value}}
			if first {
				pool[0], pool[1] = pool[1], pool[0]
			}
			run(fmt.Sprintf("exceptional/%x/first=%t", math.Float64bits(value), first), pool, false)
		}
	}
	t.Logf("review differential cases=%d decisions=%d nonempty_zero_choices=%d digest=%x", cases, decisions, zeroChoices, resultHash.Sum(nil))
}
