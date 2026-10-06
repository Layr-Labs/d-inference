package registry_test

import (
	"fmt"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// TestQualityCapDefaultOvercommitIgnoresStaleConfigFallback pins the default
// change: main.go still passes config.ReadConfig's legacy 2.0 fallback when
// EIGENINFERENCE_QUALITY_CONCURRENCY_OVERCOMMIT is unset, and
// SetQualityConcurrencyCap must override that stale argument with the package
// default (1.2) — otherwise the production default silently stays 2.0.
func TestQualityCapDefaultOvercommitIgnoresStaleConfigFallback(t *testing.T) {
	t.Setenv(env.EnvPrefix+"_QUALITY_CONCURRENCY_OVERCOMMIT", "")
	reg := newQualityRegistry(testLogger())
	reg.SetQualityConcurrencyCap(true, 2.0, 15, 4) // exactly main.go's call with the env unset

	fast := qualityProvider(t, reg, "fast", qwenBuild, 57)
	budgetSlot(fast, 0)
	want := wantQualityCap(57, 15, 24, defaultQualityCapOvercommit)
	stale := wantQualityCap(57, 15, 24, 2.0)
	if want == stale {
		t.Fatalf("test is blind at k=%.2f: overcommit 1.2 and the stale 2.0 both give cap %d — pick a solo rate that discriminates", effectiveTPSLoadFactor, want)
	}
	if got := effCap(reg, fast, qwenBuild); got != want {
		t.Fatalf("effective cap = %d, want %d (default 1.2 must apply, not the stale 2.0 config fallback → %d)", got, want, stale)
	}
}

// TestQualityCapOvercommitDilution is the cap math from the production incident:
// overcommit 2.0 admits enough concurrency that the projected per-request decode
// rate (solo/(1+k·B) at B = cap) collapses to roughly HALF the floor on fast
// boxes, while 1.2 holds it inside the realized allowance
// (maxOvercommitDilution). Caps are k-derived; the dilution CONTRAST is the
// invariant.
func TestQualityCapOvercommitDilution(t *testing.T) {
	const floor = 15.0
	for _, tc := range []struct {
		name          string
		overcommitEnv string
		overcommit    float64
		solo          float64
	}{
		{"gemma23_at_1.2", "1.2", 1.2, 23},
		{"gemma23_at_2.0", "2.0", 2.0, 23},
		{"solo30_at_1.2", "1.2", 1.2, 30},
		{"solo30_at_2.0", "2.0", 2.0, 30},
		{"solo57_at_1.2", "1.2", 1.2, 57},
		{"solo57_at_2.0", "2.0", 2.0, 57},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reg := newQualityRegistry(testLogger())
			enableQualityCap(t, reg, tc.overcommitEnv)
			p := qualityProvider(t, reg, "box", gemmaBuild, tc.solo)
			budgetSlot(p, 0)
			got := effCap(reg, p, gemmaBuild)
			want := wantQualityCap(tc.solo, floor, 24, tc.overcommit)
			if got != want {
				t.Fatalf("solo %.0f tok/s at overcommit %s: cap = %d, want %d (k=%.2f)", tc.solo, tc.overcommitEnv, got, want, effectiveTPSLoadFactor)
			}
			// The dilution difference in decode terms: projected per-request TPS
			// once the box is filled to its cap.
			projected := tc.solo / (1 + effectiveTPSLoadFactor*float64(got))
			if tc.overcommit == 2.0 && tc.solo == 57 && projected >= floor*0.6 {
				t.Fatalf("overcommit 2.0 on a 57 tok/s box projects %.1f tok/s at cap %d — expected roughly half the %.0f floor", projected, got, floor)
			}
			bound := floor / maxOvercommitDilution(effectiveTPSLoadFactor, tc.overcommit)
			if tc.overcommit == 1.2 && projected < bound-1e-9 {
				t.Fatalf("overcommit 1.2 on a %.0f tok/s box projects %.1f tok/s at cap %d — must stay ≥ %.2f (floor / realized allowance %.3f at k=%.2f)",
					tc.solo, projected, got, bound, maxOvercommitDilution(effectiveTPSLoadFactor, 1.2), effectiveTPSLoadFactor)
			}
		})
	}
}

// TestQualityCapPerModelOverride: a model listed in
// EIGENINFERENCE_QUALITY_CONCURRENCY_OVERCOMMIT_BY_MODEL uses its own
// overcommit (matched case-insensitively on the resolved build id); malformed
// or non-positive entries are skipped so those models keep the global value.
func TestQualityCapPerModelOverride(t *testing.T) {
	t.Setenv(qualityCapOvercommitByModelEnv,
		"GEMMA-4-26B-QAT-4BIT=1.0, bogus, =3, "+qwenBuild+"=abc")
	reg := newQualityRegistry(testLogger())
	enableQualityCap(t, reg, "2.0")

	gemma := qualityProvider(t, reg, "gemma-box", gemmaBuild, 30)
	budgetSlot(gemma, 0)
	qwen := qualityProvider(t, reg, "qwen-box", qwenBuild, 30)
	budgetSlot(qwen, 0)

	wantOverridden := wantQualityCap(30, 15, 24, 1.0)
	wantGlobal := wantQualityCap(30, 15, 24, 2.0)
	if got := effCap(reg, gemma, gemmaBuild); got != wantOverridden {
		t.Fatalf("override model cap = %d, want %d (per-model overcommit 1.0 × quality batch, uppercase key must match)", got, wantOverridden)
	}
	if got := effCap(reg, qwen, qwenBuild); got != wantGlobal {
		t.Fatalf("non-override model cap = %d, want %d (malformed entry skipped → global overcommit 2.0)", got, wantGlobal)
	}
}

// TestQualityCapPerModelOverrideAbsentUsesGlobalDefault: with an override map
// that does not mention the model and no global env set, the model uses the
// package default (1.2).
func TestQualityCapPerModelOverrideAbsentUsesGlobalDefault(t *testing.T) {
	t.Setenv(qualityCapOvercommitByModelEnv, "some-other-model=1.0")
	reg := newQualityRegistry(testLogger())
	enableQualityCap(t, reg, "")

	p := qualityProvider(t, reg, "fast", qwenBuild, 57)
	budgetSlot(p, 0)
	want := wantQualityCap(57, 15, 24, defaultQualityCapOvercommit)
	if got := effCap(reg, p, qwenBuild); got != want {
		t.Fatalf("cap = %d, want %d (no per-model entry → default 1.2 × quality batch)", got, want)
	}
}

// TestQualityCapNeverBelowOneAndProviderCapClamps: a vanishingly small
// per-model overcommit still leaves the cap at 1 (a provider is never fully
// closed), and a provider-reported per-slot cap TIGHTER than the quality math
// still binds (the hardware/self-reported clamp is preserved).
func TestQualityCapNeverBelowOneAndProviderCapClamps(t *testing.T) {
	t.Setenv(qualityCapOvercommitByModelEnv, gemmaBuild+"=0.01")
	reg := newQualityRegistry(testLogger())
	enableQualityCap(t, reg, "")

	slow := qualityProvider(t, reg, "slow", gemmaBuild, 23) // qc 1
	budgetSlot(slow, 0)
	if got := effCap(reg, slow, gemmaBuild); got != 1 {
		t.Fatalf("cap = %d, want 1 (ceil(qc 1 × 0.01) clamps to 1, never 0)", got)
	}

	tight := qualityProvider(t, reg, "tight", qwenBuild, 57) // quality would allow 12
	tight.Mu().Lock()
	tight.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 500_000
	tight.BackendCapacity.Slots[0].MaxConcurrency = 1
	tight.Mu().Unlock()
	if got := effCap(reg, tight, qwenBuild); got != 1 {
		t.Fatalf("cap = %d, want 1 (provider-reported slot cap 1 binds below the quality cap)", got)
	}
}

// TestQualityCapProjectedDecodeTPSAtDefaultHoldsNearFloor is the decode-floor
// guarantee of the 1.2 default: a provider filled to its admitted cap still
// projects per-request decode (rate(B) = solo/(1+k·B), the same degradation
// model the package routes with) inside the REALIZED overcommit allowance —
// see maxOvercommitDilution for why that is strictly worse than the nominal
// 1.2 and why pinning floor/1.2 here is pinning a guarantee the code does not
// make. The old 2.0 default, by contrast, let decode collapse to half the
// floor.
func TestQualityCapProjectedDecodeTPSAtDefaultHoldsNearFloor(t *testing.T) {
	const floor = 15.0
	reg := newQualityRegistry(testLogger())
	enableQualityCap(t, reg, "")

	bound := floor / maxOvercommitDilution(effectiveTPSLoadFactor, defaultQualityCapOvercommit)
	for i, solo := range []float64{20, 23, 30, 45, 57, 80, 100} {
		p := qualityProvider(t, reg, fmt.Sprintf("box-%d", i), gemmaBuild, solo)
		budgetSlot(p, 0)
		admitted := effCap(reg, p, gemmaBuild)
		projected := solo / (1 + effectiveTPSLoadFactor*float64(admitted))
		if projected < bound-1e-9 {
			t.Errorf("solo %.0f tok/s: cap %d projects %.2f tok/s — below the realized allowance bound %.2f (k=%.2f)",
				solo, admitted, projected, bound, effectiveTPSLoadFactor)
		}
	}
	// And that bound must stay meaningfully tighter than the collapse it
	// replaced: overcommit 2.0 permits exactly half the floor.
	if bound <= floor/2 {
		t.Fatalf("realized 1.2 allowance bound %.2f is no better than the 2.0 collapse (%.2f) at k=%.2f — the default no longer buys anything",
			bound, floor/2, effectiveTPSLoadFactor)
	}

	// Contrast with the old default on a fast box: 2.0 dilutes past the bound
	// the new default holds.
	diluted := newQualityRegistry(testLogger())
	enableQualityCap(t, diluted, "2.0")
	p := qualityProvider(t, diluted, "diluted", gemmaBuild, 57)
	budgetSlot(p, 0)
	admitted := effCap(diluted, p, gemmaBuild)
	projected := 57 / (1 + effectiveTPSLoadFactor*float64(admitted))
	if projected >= bound {
		t.Fatalf("overcommit 2.0 projects %.2f tok/s at cap %d — expected below the %.2f bar the 1.2 default enforces", projected, admitted, bound)
	}
}
