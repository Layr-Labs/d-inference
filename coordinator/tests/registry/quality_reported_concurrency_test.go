package registry_test

import (
	"fmt"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// TestQualityCapReachesProviderReportedConcurrency is the RELATIONSHIP the
// v0.8.0 engine bump rides on, pinned instead of a literal: a provider that
// reports N concurrent slots is granted all N exactly when its solo decode rate
// clears a threshold derived from (floor, k, overcommit) — and the CBv2
// measured gemma-4 solo rate clears the N=8 threshold with room to spare.
//
// Raising engine_v2_max_concurrent alone does NOT buy coordinator-visible
// concurrency: the provider-reported number is only the `base` operand of a MIN
// against the quality cap, so the solo rate the coordinator RESOLVES for the
// model is what decides whether the bump is real. That is why prod needs a
// gemma-4 entry in EIGENINFERENCE_MODEL_SOLO_TPS_SEED (see
// TestQualityCapEightRequiresSoloRateNotOvercommit).
func TestQualityCapReachesProviderReportedConcurrency(t *testing.T) {
	const floor = 15.0
	// See measured_rates_test.go: this is the PER-REQUEST paged rate from the
	// engine benchmark, not the aggregate rate the v0.8.0 gate report quotes.
	const measuredGemmaSoloTPS = measuredGemmaSoloTPSPaged

	for _, base := range []int{4, 8} {
		t.Run(fmt.Sprintf("base%d", base), func(t *testing.T) {
			threshold := soloTPSForCap(floor, base, defaultQualityCapOvercommit)

			mk := func(reg *qualityFixture,

				id string, solo float64) *production.Provider {
				p := qualityProvider(t, reg, id, gemmaBuild, solo)
				p.Mu().Lock()
				p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 500_000
				p.BackendCapacity.Slots[0].MaxConcurrency = base
				p.Mu().Unlock()
				return p
			}

			reg := newQualityRegistry(testLogger())
			enableQualityCap(t, reg, "")

			// At the threshold the provider's whole reported cap is granted.
			if got := effCap(reg, mk(reg, "at", threshold), gemmaBuild); got != base {
				t.Fatalf("solo %.2f tok/s (derived threshold at k=%.2f): cap = %d, want the full reported %d",
					threshold, effectiveTPSLoadFactor, got, base)
			}
			// A quarter of a tok/s below it, it is not — the threshold is a real
			// edge, not a rounding artifact of the assertion above.
			if got := effCap(reg, mk(reg, "below", threshold-0.25), gemmaBuild); got >= base {
				t.Fatalf("solo %.2f tok/s (just under the threshold): cap = %d, want < %d", threshold-0.25, got, base)
			}
			// And the engine's measured rate is on the granting side of it: the
			// provider bump is reachable on real hardware without relaxing the
			// quality bar.
			if measuredGemmaSoloTPS < threshold {
				t.Fatalf("measured gemma-4 solo %.1f tok/s is BELOW the %.2f tok/s needed for cap %d at floor %.0f / k %.2f / overcommit %.1f — the engine bump cannot land",
					measuredGemmaSoloTPS, threshold, base, floor, effectiveTPSLoadFactor, defaultQualityCapOvercommit)
			}
			if got := effCap(reg, mk(reg, "measured", measuredGemmaSoloTPS), gemmaBuild); got != base {
				t.Fatalf("measured gemma-4 solo %.1f tok/s: cap = %d, want the full reported %d", measuredGemmaSoloTPS, got, base)
			}
		})
	}
}

// TestQualityCapEightRequiresSoloRateNotOvercommit is the config question the
// v0.8.0 rollout actually has to answer, pinned as behavior.
//
// In production the Swift provider never sends decode_tps, so without a solo
// source the cap is computed from resolvedDecodeTPS's sqrt(memory_bandwidth)
// proxy — 16-28 tok/s across Apple silicon, a MODEL-AGNOSTIC number that has
// nothing to do with gemma-4 and lands at or under the floor. Whether that
// arrives as the proxy or as a low seed, the answer is the same: a provider
// reporting 8 is capped at 2, at any measured k.
//
// EIGENINFERENCE_QUALITY_CONCURRENCY_OVERCOMMIT_BY_MODEL can force it to 8 —
// the plumbing works, config-only — but only above a multiplier of 7, which is
// not an overcommit allowance, it is switching the cap off: at that setting the
// projected per-request decode collapses below even the half-floor the 2.0
// default was reverted for. Seeding the model's real solo rate reaches 8 on
// quality merit at the default 1.2 and keeps the bar intact.
func TestQualityCapEightRequiresSoloRateNotOvercommit(t *testing.T) {
	const floor = 15.0
	// starvedSoloTPS stands in for what prod resolves today: the sqrt(546) ≈ 23
	// M4 Max bandwidth proxy, or an equally low seed. Both cap at 2.
	const starvedSoloTPS = 14.0
	// prodSeedTPS is the value EIGENINFERENCE_MODEL_SOLO_TPS_SEED should carry.
	// It is deliberately well under the engine's measured 99.5 tok/s solo rate
	// so slower fleet tiers are not over-credited, while still clearing the
	// reachability threshold at BOTH the shipped k (39.3 tok/s) and the CBv2
	// re-fit (50.1 tok/s) — so the config survives the coefficient move.
	const prodSeedTPS = 70.0
	mk := func(t *testing.T, reg *qualityFixture,

	) *production.Provider {
		p := mixedBoxProvider(t, reg, "v0.8.0-box", 93)
		p.Mu().Lock()
		for i := range p.BackendCapacity.Slots {
			if p.BackendCapacity.Slots[i].Model == gemmaBuild {
				p.BackendCapacity.Slots[i].MaxConcurrency = 8
			}
		}
		p.Mu().Unlock()
		return p
	}

	t.Run("reported_eight_alone_is_not_enough", func(t *testing.T) {
		reg := newQualityRegistry(testLogger())
		enablePerModelQualityCap(t, reg, gemmaBuild+"="+fmt.Sprint(starvedSoloTPS), "", "")
		if got := effCapResolved(reg, mk(t, reg), gemmaBuild); got != 2 {
			t.Fatalf("cap = %d, want 2: a provider-reported 8 is only the MIN's base operand; the %.0f tok/s solo rate decides", got, starvedSoloTPS)
		}
	})

	t.Run("per_model_overcommit_reaches_eight_but_voids_the_bar", func(t *testing.T) {
		reg := newQualityRegistry(testLogger())
		t.Setenv(qualityCapOvercommitByModelEnv, gemmaBuild+"=7.5")
		enablePerModelQualityCap(t, reg, gemmaBuild+"="+fmt.Sprint(starvedSoloTPS), "", "")
		got := effCapResolved(reg, mk(t, reg), gemmaBuild)
		if got != 8 {
			t.Fatalf("per-model overcommit 7.5: cap = %d, want 8 (the override plumbing must be config-only)", got)
		}
		// Anything at or under 7 leaves the quality batch of 1 short of 8, so
		// this route has no setting that both reaches 8 and stays an allowance.
		reg7 := newQualityRegistry(testLogger())
		t.Setenv(qualityCapOvercommitByModelEnv, gemmaBuild+"=7.0")
		enablePerModelQualityCap(t, reg7, gemmaBuild+"="+fmt.Sprint(starvedSoloTPS), "", "")
		if got := effCapResolved(reg7, mk(t, reg7), gemmaBuild); got != 7 {
			t.Fatalf("per-model overcommit 7.0: cap = %d, want 7 — the route to 8 needs a multiplier ABOVE 7", got)
		}
		projected := starvedSoloTPS / (1 + effectiveTPSLoadFactor*8)
		if projected >= floor/2 {
			t.Fatalf("overcommit-to-8 projects %.2f tok/s — expected below half the %.0f floor, i.e. worse than the 2.0 default that was reverted", projected, floor)
		}
	})

	t.Run("seeded_solo_rate_reaches_eight_on_quality_merit", func(t *testing.T) {
		reg := newQualityRegistry(testLogger())
		enablePerModelQualityCap(t, reg, gemmaBuild+"="+fmt.Sprint(prodSeedTPS), "", "")
		if got := effCapResolved(reg, mk(t, reg), gemmaBuild); got != 8 {
			t.Fatalf("seeded at %.0f tok/s: cap = %d, want 8 at the default overcommit (k=%.2f)", prodSeedTPS, got, effectiveTPSLoadFactor)
		}
		// And it must be granted on QUALITY, not bought with the overcommit
		// allowance: the strict quality batch alone has to reach 8, so the
		// projected per-request rate at B=8 stays at or above the floor.
		if qc := strictQualityBatch(prodSeedTPS, floor, effectiveTPSLoadFactor, 8); qc != 8 {
			t.Fatalf("seed %.0f gives a strict quality batch of %d at k=%.2f — 8 would be reached only via the overcommit rounding; raise the seed", prodSeedTPS, qc, effectiveTPSLoadFactor)
		}
		if projected := prodSeedTPS / (1 + effectiveTPSLoadFactor*8); projected < floor {
			t.Fatalf("seeded route projects %.2f tok/s at B=8 — below the %.0f floor, so the seed would be buying concurrency the quality bar should refuse", projected, floor)
		}
	})
}
