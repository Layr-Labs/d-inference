package registry

import "testing"

// Gate G0a for the v0.8.0 PagedAttention migration: does the coordinator
// actually dispatch 8?
//
// The migration plan's Rev 1 claimed "no code change is required to test the
// batching hypothesis." That was wrong: the provider-reported max_concurrency
// is only the `base` operand of a MIN against the coordinator's quality cap,
// and the quality cap is computed from a single-stream decode rate the
// coordinator has to actually possess. With no real measurement it falls back
// to a sqrt(memory_bandwidth) hardware proxy that is model-agnostic and far
// below what gemma-4 really does, which pins the cap near 1.
//
// The decode rates below are MEASURED, not modelled: gemma-4-26B-A4B-it-qat-4bit
// on an Apple M4 Max (40 GPU cores, 546 GB/s), release build, medians of five
// repetitions. See docs/reports/2026-07-25-paged-gate-results.md.
const (
	// Solo (B=1) aggregate decode, measured.
	measuredSoloTPSPaged      = 98.8
	measuredSoloTPSContiguous = 107.2

	// The bandwidth proxy the coordinator falls back to with no real
	// measurement: sqrt(546) ~= 23.4 tok/s.
	bandwidthProxyTPS = 23.4

	// EIGENINFERENCE_MIN_DECODE_TPS, deploy/environments/prod.env:27.
	prodFloorTPS = 15.0

	// Engine ceiling: ProviderConfig.swift engineV2MaxConcurrent clamps to
	// [1, 8] and CBv2Contracts documents 8 as the product target.
	engineCeiling = 8
)

func TestGateG0AQualityCapReachesEightOnMeasuredRates(t *testing.T) {
	for _, tc := range []struct {
		name string
		tps  float64
	}{
		{"paged", measuredSoloTPSPaged},
		{"contiguous", measuredSoloTPSContiguous},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := qualityConcurrency(tc.tps, prodFloorTPS, effectiveTPSLoadFactor, engineCeiling, engineCeiling)
			if got != engineCeiling {
				t.Fatalf("quality cap = %d, want %d: a measured solo rate of %.1f tok/s "+
					"against a %.0f tok/s floor must not clamp below the engine ceiling",
					got, engineCeiling, tc.tps, prodFloorTPS)
			}
		})
	}
}

// The cap is only reachable because a REAL per-model measurement reaches the
// coordinator. This pins the reason: on the bandwidth fallback the same
// provider is capped to 1, so B=8 would never be dispatched and Gate G0b would
// have measured nothing.
//
// SCOPE, and it is narrower than it first looks. effectiveMaxConcurrencyForModelRateLocked
// short-circuits to `base` when a provider reports no decode_tps AND the rate is
// not per-model AND the model is NOT dedicated -- deliberately, because the
// bandwidth proxy under-reads fast models and hard-capping them from it would
// shed healthy traffic. So this pinning applies to DEDICATED models, and
// gemma-4 is dedicated in production (EIGENINFERENCE_DEDICATED_MODELS=gemma-4,
// deploy/environments/prod.env:26). That is precisely the model this migration
// targets, so the guard does not spare it.
//
// If someone removes the relaxed solo-rate tier, this test is what says why
// B=8 stopped happening on gemma-4.
func TestGateG0ABandwidthFallbackWouldPinTheCapForDedicatedModels(t *testing.T) {
	got := qualityConcurrency(bandwidthProxyTPS, prodFloorTPS, effectiveTPSLoadFactor, engineCeiling, engineCeiling)
	if got >= engineCeiling {
		t.Fatalf("bandwidth-proxy cap = %d, want well below %d: if the coarse "+
			"hardware proxy already reached the ceiling, the measured-rate path "+
			"would not be load-bearing and this gate would prove nothing",
			got, engineCeiling)
	}
	if got != 1 {
		t.Logf("bandwidth-proxy cap = %d (documented as ~1); the exact value is "+
			"not the contract, the gap from %d is", got, engineCeiling)
	}
}

// The re-fitted load factor must not be so aggressive that a measured rate
// still fails to reach 8, nor so lenient that the floor stops binding at all.
// k moved 0.27 -> 0.39 when it was re-fitted against real CBv2 decode rates
// instead of legacy Qwen2.5-7B data (MAPE 23.4% -> 2.9%), which made the cap
// TIGHTER. This asserts the tightening did not overshoot past the measured
// fleet.
func TestGateG0ARefittedLoadFactorStillAdmitsTheMeasuredFleet(t *testing.T) {
	if effectiveTPSLoadFactor <= 0 {
		t.Fatalf("effectiveTPSLoadFactor = %v, must be positive", effectiveTPSLoadFactor)
	}
	// The slowest rate that still earns the full ceiling under the current k.
	// b = floor((tps/floor - 1)/k) >= 8  =>  tps >= floor*(1 + 8k).
	threshold := prodFloorTPS * (1 + float64(engineCeiling)*effectiveTPSLoadFactor)
	if measuredSoloTPSPaged < threshold {
		t.Fatalf("measured paged solo %.1f tok/s is below the %.1f tok/s needed for a "+
			"cap of %d at k=%v: the re-fit overshot the fleet it was fitted to",
			measuredSoloTPSPaged, threshold, engineCeiling, effectiveTPSLoadFactor)
	}
	t.Logf("k=%v requires %.1f tok/s for cap %d; measured paged %.1f, contiguous %.1f",
		effectiveTPSLoadFactor, threshold, engineCeiling, measuredSoloTPSPaged, measuredSoloTPSContiguous)
}
