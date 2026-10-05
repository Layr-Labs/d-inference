package registry_test

import (
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// TestQualityCapPerModelTPSPostmortemRegression is THE 2026-07-06 gemma
// postmortem layer-6 scenario: a mixed box whose registration benchmark was
// taken on gpt-oss (93 tok/s) hosts a gemma slot that actually decodes ~14
// tok/s solo. The old cap consumed the provider-LEVEL rate for every model, so
// gemma inherited the benchmark's wide cap — and the coordinator marched 8–11
// concurrent gemma requests onto exactly the boxes that collapse past batch 3.
// With the per-model solo source, gemma's cap must come from gemma's own solo
// median (14 ≤ floor 15 → quality batch 1 → cap 2, at any measured k) while
// gpt-oss keeps its wide benchmark-derived cap. Reverting the resolver wiring
// makes the gemma assertion fail (it inherits the gpt-oss cap again).
func TestQualityCapPerModelTPSPostmortemRegression(t *testing.T) {
	run := func(t *testing.T, seedGemma func(reg *qualityFixture,

	)) {
		reg := newQualityRegistry(testLogger())
		enablePerModelQualityCap(t, reg, "", "", "")
		seedGemma(reg)
		p := mixedBoxProvider(t, reg, "mixed-93", 93)
		wantGptoss := wantQualityCap(93, 15, 24, defaultQualityCapOvercommit)
		if got := effCapResolved(reg, p, gemmaBuild); got != 2 {
			t.Fatalf("gemma cap on the mixed box = %d, want 2 (solo 14 ≤ floor 15 → quality batch 1 × overcommit 1.2; NOT the benchmark-derived %d)", got, wantGptoss)
		}
		if got := effCapResolved(reg, p, gptossBuild); got != wantGptoss {
			t.Fatalf("gpt-oss cap on the mixed box = %d, want %d (its own 93 tok/s benchmark stays wide at k=%.2f)", got, wantGptoss, effectiveTPSLoadFactor)
		}
	}

	t.Run("solo_median_recorded", func(t *testing.T) {
		run(t, func(reg *qualityFixture,

		) {
			for _, v := range []float64{12, 13, 14, 15, 16} {
				reg.throughput.RecordSolo(gemmaBuild, "M3|Max", v)
			}
		})
	})
	t.Run("seed_env_cold_start", func(t *testing.T) {
		run(t, func(reg *qualityFixture,

		) {
			t.Setenv(modelSoloTPSSeedEnv, gemmaBuild+"=14")
			// Re-parse with the seed present (startup order: env → setter).
			enableQualityCap(t, reg, "")
		})
	})
}

// TestQualityCapSeedBoundsCrossClassTransfer pins cold-class safety when the
// only live solo samples come from a faster chip class. A configured model seed
// is the conservative cold-start estimate for an unsampled class, so faster
// cross-class observations must not widen that class's quality cap above it.
func TestQualityCapSeedBoundsCrossClassTransfer(t *testing.T) {
	reg := newQualityRegistry(testLogger())
	enablePerModelQualityCap(t, reg, gemmaBuild+"=14", "", "")
	p := mixedBoxProvider(t, reg, "unsampled-slow-class", 93)
	p.Mu().Lock()
	p.Hardware.ChipFamily = "M2"
	p.Hardware.ChipTier = "Pro"
	p.Mu().Unlock()

	for i := 0; i < reg.policy.MinSamples(); i++ {
		reg.throughput.RecordSolo(gemmaBuild, "M4|Max", 40)
	}

	if got := resolveSolo(reg, p, gemmaBuild); got.TPS != 14 || !got.PerModel {
		t.Fatalf("unsampled slow-class resolver = %+v, want seed 14 (faster cross-class median 40 must not override the configured cold-start bound)", got)
	}
}

// TestQualityCapPerModelTPSKillSwitchRestoresOldBehavior pins the kill switch:
// EIGENINFERENCE_QUALITY_CAP_PER_MODEL_TPS=false must restore the provider-
// level resolvedDecodeTPS(p) at the cap exactly — reproducing the postmortem's
// buggy WIDE gemma cap (inherited from the gpt-oss benchmark) even though a
// trusted gemma solo median exists. This doubles as the proof that the
// regression test above fails without the fix: the old code path IS the
// switch-off path.
func TestQualityCapPerModelTPSKillSwitchRestoresOldBehavior(t *testing.T) {
	reg := newQualityRegistry(testLogger())
	enablePerModelQualityCap(t, reg, gemmaBuild+"=14", "false", "")
	for range 10 {
		reg.throughput.RecordSolo(gemmaBuild, "M3|Max", 14)
	}
	p := mixedBoxProvider(t, reg, "mixed-93", 93)

	wantLegacy := wantQualityCap(93, 15, 24, defaultQualityCapOvercommit)
	if got := effCapResolved(reg, p, gemmaBuild); got != wantLegacy {
		t.Fatalf("kill switch off: gemma cap = %d, want the old provider-level %d (byte-for-byte legacy behavior)", got, wantLegacy)
	}
	// And it must match the explicit provider-level path exactly.
	if resolved, legacy := effCapResolved(reg, p, gemmaBuild), effCap(reg, p, gemmaBuild); resolved != legacy {
		t.Fatalf("kill switch off: resolved cap %d != legacy explicit-rate cap %d", resolved, legacy)
	}
}

// TestQualityCapPerModelRateCapsWithoutRegistrationBenchmark: the DecodeTPS<=0
// guard exists because the sqrt-bandwidth fallback is model-agnostic — but a
// PER-MODEL rate (solo median / seed) is trustworthy by construction, so a
// non-dedicated model on a benchmark-less box is still capped from it. Without
// any per-model source the old guard semantics hold (flat cap).
func TestQualityCapPerModelRateCapsWithoutRegistrationBenchmark(t *testing.T) {
	reg := newQualityRegistry(testLogger())
	enablePerModelQualityCap(t, reg, "", "", "")
	for i := 0; i < 5; i++ {
		reg.throughput.RecordSolo(gemmaBuild, "M3|Max", 14)
	}

	mkNoBenchmark := func(id string) *production.Provider {
		p := mixedBoxProvider(t, reg, id, 0) // DecodeTPS unset
		p.Mu().Lock()
		p.Hardware.MemoryBandwidthGBs = 800 // sqrt(800) ≈ 28 fallback
		p.Mu().Unlock()
		return p
	}

	// Solo median present → capped even without a registration benchmark.
	p := mkNoBenchmark("no-bench")
	if got := effCapResolved(reg, p, gemmaBuild); got != 2 {
		t.Fatalf("no-benchmark box with solo median: gemma cap = %d, want 2", got)
	}
	// No per-model source (gpt-oss): non-dedicated + bandwidth fallback → the
	// old guard keeps the flat cap (don't shed a fast model on a coarse proxy).
	if got := effCapResolved(reg, p, gptossBuild); got != 24 {
		t.Fatalf("no-benchmark box without per-model source: gpt-oss cap = %d, want flat 24", got)
	}
}
