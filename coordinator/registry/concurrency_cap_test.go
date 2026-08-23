package registry

import (
	"fmt"
	"math"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// budgetSlot turns a makeSchedulerProvider box into a token-budget provider (the
// real Gemma/gpt-oss shape) so its legacy flat concurrency fallback is 24 — the
// value the quality cap must tighten. Optionally injects a collapsed observed
// decode EWMA to prove the cap reads the STATIC rate, not the observed one.
func budgetSlot(p *Provider, observedDecodeTPS float64) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 500_000
	p.BackendCapacity.Slots[0].ObservedDecodeTPS = observedDecodeTPS
}

// effCap evaluates the registry's effective per-model concurrency cap for p
// under the locks the routing path holds, using the provider's STATIC decode
// rate (mirrors snapshotProviderLockedEx / quickCapacityCheck).
func effCap(reg *Registry, p *Provider, model string) int {
	reg.mu.RLock()
	defer reg.mu.RUnlock()
	p.mu.Lock()
	defer p.mu.Unlock()
	return reg.effectiveMaxConcurrencyForModelLocked(p, model, resolvedDecodeTPS(p))
}

// enableQualityCap enables the cap with the production floor (15) and fallback
// (4), wired exactly as main.go does: the overcommit argument is whatever
// config.ReadConfig parsed — the operator's env value when set, else the legacy
// 2.0 fallback that SetQualityConcurrencyCap must override with the package
// default. overcommitEnv "" pins the env var EMPTY (treated as unset → the
// default applies), isolating the test from any ambient operator setting.
func enableQualityCap(t *testing.T, reg *Registry, overcommitEnv string) {
	t.Helper()
	key := env.EnvPrefix + "_QUALITY_CONCURRENCY_OVERCOMMIT"
	t.Setenv(key, overcommitEnv)
	reg.SetQualityConcurrencyCap(true, env.EnvFloat(key, 2.0), 15, 4)
}

// --- k-derived expectations --------------------------------------------------
//
// effectiveTPSLoadFactor is MEASURED, not chosen: the shipped 0.27 was fitted on
// a legacy engine (Qwen2.5-7B-4bit), and the CBv2 decode curves for the models
// this coordinator actually serves re-fit it to ~0.39 (median implied k over
// B = 2/4/8; libs/mlx-swift-lm/benchmarks/reports/gemma4-26b-qat4bit-paged-gate-2026-07-09.md).
// Every cap integer below is a function of that coefficient, so hard-coding the
// integers means one re-measurement invalidates a dozen tests that are not about
// arithmetic at all — and teaches the next reader nothing about WHY the number
// is what it is. The tests therefore pin the RELATIONSHIP
// cap = f(solo, floor, k, base, overcommit); the closed form itself is pinned
// once, against an independent derivation, by
// TestQualityConcurrencyMatchesDefiningInequality.

// strictQualityBatch answers qualityConcurrency's question from its DEFINING
// inequality — the largest batch B in [1, limit] whose projected per-request
// rate solo/(1+k·B) still clears floor — by search instead of algebra. It is
// deliberately not the closed form, so it can catch an off-by-one or a dropped
// clamp in floor((solo/floor - 1)/k). Like the closed form it never returns 0:
// a provider is never fully closed, even for a model that misses the floor at
// B=1.
func strictQualityBatch(solo, floor, k float64, limit int) int {
	if limit < 1 {
		limit = 1
	}
	if floor <= 0 || solo <= 0 || k <= 0 {
		return limit
	}
	best := 1
	for b := 1; b <= limit; b++ {
		if solo/(1+k*float64(b)) >= floor {
			best = b
		}
	}
	return best
}

// wantQualityCap is the cap effectiveMaxConcurrencyForModelRateLocked must
// produce for a provider whose per-slot/flat limit is base: the strict quality
// batch grown by the overcommit allowance, never below 1, never above base.
func wantQualityCap(solo, floor float64, base int, overcommit float64) int {
	capped := int(math.Ceil(float64(strictQualityBatch(solo, floor, effectiveTPSLoadFactor, base)) * overcommit))
	if capped < 1 {
		capped = 1
	}
	if capped < base {
		return capped
	}
	return base
}

// soloTPSForCap inverts wantQualityCap: the smallest solo decode rate at which a
// provider reporting `base` concurrent slots is actually granted all of them.
// The cap is monotone non-decreasing in the solo rate, so a bisection is exact
// to the returned tolerance. This is the number an operator needs to size
// EIGENINFERENCE_MODEL_SOLO_TPS_SEED, and the number that moves when k moves.
func soloTPSForCap(floor float64, base int, overcommit float64) float64 {
	lo, hi := 0.0, floor
	for wantQualityCap(hi, floor, base, overcommit) < base {
		lo, hi = hi, hi*2
		if hi > 1e6 {
			return math.Inf(1)
		}
	}
	for i := 0; i < 200 && hi-lo > 1e-9; i++ {
		mid := (lo + hi) / 2
		if wantQualityCap(mid, floor, base, overcommit) < base {
			lo = mid
		} else {
			hi = mid
		}
	}
	return hi
}

// maxOvercommitDilution is the largest factor by which admitting at the
// overcommitted cap can push per-request decode below the quality floor.
//
// The nominal allowance is the overcommit itself, but the realized one is
// strictly worse: cap = ceil(qc × overcommit) rounds UP, which at qc = 1 turns
// an overcommit of 1.2 into a factor of 2. With rate(B) = solo/(1+k·B), the
// quality batch's defining solo >= floor·(1+k·qc), and ceil(x) < x+1:
//
//	rate(cap) > floor·(1+k·qc) / (1 + k·(overcommit·qc + 1))
//
// That ratio is monotone in qc — increasing when overcommit < 1+k, decreasing
// otherwise — so its infimum is the worse of the qc = 1 endpoint and the
// qc → infinity asymptote (1/overcommit). Pinning the NOMINAL floor/overcommit
// instead would be pinning a bound the implementation does not provide: it
// holds at k = 0.27 by luck of the rounding and fails at k = 0.39.
func maxOvercommitDilution(k, overcommit float64) float64 {
	return math.Max((1+k+k*overcommit)/(1+k), overcommit)
}

// TestQualityCapUsesStaticNotObservedTPS is the regression that matters: a slow
// model's box is capped from its STATIC single-stream rate (~23 tok/s → quality
// batch 1 → cap 2 = ceil(1 × 1.2) at the default overcommit), and the collapsed
// observed-under-load EWMA (~2.6 tok/s, which would force a cap of 1) must NOT
// change the result — otherwise the cap inherits the very feedback loop it
// exists to break.
func TestQualityCapUsesStaticNotObservedTPS(t *testing.T) {
	reg := New(testLogger())
	enableQualityCap(t, reg, "")
	p := makeSchedulerProvider(t, reg, "gemma-box", gemmaBuild, 23) // static 23 tok/s
	budgetSlot(p, 2.6)                                              // collapsed observed EWMA

	if got := effCap(reg, p, gemmaBuild); got != 2 {
		t.Fatalf("effective cap = %d, want 2 (quality batch 1 from STATIC 23 tok/s × default overcommit, ignoring observed 2.6)", got)
	}
}

// TestQualityCapScalesWithModelSpeed shows the cap is universal and self-tuning:
// a fast model (57 tok/s) keeps a high cap — an order above normal load — that
// never bites, while a slow model (23 tok/s, quality batch 1 at any measured k)
// is tightened to 2. The fast side is k-derived: it is 12 at k = 0.27 and 9 at
// the CBv2-re-fit 0.39, and neither number is the point.
func TestQualityCapScalesWithModelSpeed(t *testing.T) {
	reg := New(testLogger())
	enableQualityCap(t, reg, "")

	slow := makeSchedulerProvider(t, reg, "slow", gemmaBuild, 23)
	budgetSlot(slow, 0)
	fast := makeSchedulerProvider(t, reg, "fast", qwenBuild, 57)
	budgetSlot(fast, 0)

	if got := effCap(reg, slow, gemmaBuild); got != 2 {
		t.Fatalf("slow cap = %d, want 2", got)
	}
	wantFast := wantQualityCap(57, 15, 24, defaultQualityCapOvercommit)
	if got := effCap(reg, fast, qwenBuild); got != wantFast {
		t.Fatalf("fast cap = %d, want %d (ceil(quality batch × 1.2) at k=%.2f, ≤ flat 24) — far above normal load, no regression", got, wantFast, effectiveTPSLoadFactor)
	}
	if wantFast <= 4 {
		t.Fatalf("fast cap %d collapsed to slow-model territory at k=%.2f — a 57 tok/s model must keep real headroom", wantFast, effectiveTPSLoadFactor)
	}
}

// TestQualityCapFallbackRateOnlyCapsDedicated guards the P1 regression: when a
// provider has NOT reported a real decode benchmark (DecodeTPS==0), resolvedDecodeTPS
// falls back to sqrt(memory_bandwidth) — a model-agnostic hardware proxy that
// under-estimates fast models. The cap must therefore bite only DEDICATED models
// from that fallback; a non-dedicated model keeps the flat cap (so healthy
// fast-model traffic isn't shed on a bad rate estimate).
func TestQualityCapFallbackRateOnlyCapsDedicated(t *testing.T) {
	reg := New(testLogger())
	reg.SetDedicatedModels([]string{"gemma-4"})
	enableQualityCap(t, reg, "")

	// No DecodeTPS benchmark; rate comes from sqrt(bandwidth)=sqrt(800)≈28.
	mkFallback := func(id, model string) *Provider {
		p := makeSchedulerProvider(t, reg, id, model, 0) // DecodeTPS unset
		p.mu.Lock()
		p.Hardware.MemoryBandwidthGBs = 800
		p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 500_000
		p.mu.Unlock()
		return p
	}

	// Non-dedicated on the fallback rate → NOT capped (flat 24): don't shed a fast
	// model on a hardware proxy that can't see its true ~57 tok/s rate.
	nonDed := mkFallback("qwen-box", qwenBuild)
	if got := effCap(reg, nonDed, qwenBuild); got != 24 {
		t.Fatalf("non-dedicated fallback-rate cap = %d, want 24 (no benchmark → not capped from sqrt(bw))", got)
	}

	// Dedicated on the same fallback rate → capped (best-effort): qc from ~28 tok/s.
	ded := mkFallback("gemma-box", gemmaBuild)
	if got := effCap(reg, ded, gemmaBuild); got >= 24 || got < 1 {
		t.Fatalf("dedicated fallback-rate cap = %d, want a tightened value < 24 (dedicated capped even without a benchmark)", got)
	}
}

// TestQualityCapDisabledKeepsFlatCap: with the cap off, the legacy flat
// token-budget fallback (24) applies unchanged.
func TestQualityCapDisabledKeepsFlatCap(t *testing.T) {
	reg := New(testLogger())
	reg.SetQualityConcurrencyCap(false, 2.0, 15, 4)
	p := makeSchedulerProvider(t, reg, "gemma-box", gemmaBuild, 23)
	budgetSlot(p, 2.6)
	if got := effCap(reg, p, gemmaBuild); got != 24 {
		t.Fatalf("effective cap = %d, want 24 (cap disabled → flat fallback)", got)
	}
}

// TestQualityCapTakesMinOfReportedAndQuality: the effective cap is the MINIMUM of
// the provider-reported per-slot cap and the quality cap. A provider that reports
// a LOOSE cap (8) for a slow model is still held to the quality bar (2); a
// provider that reports a TIGHTER cap (1) than quality binds at 1. Neither path
// over-admits.
func TestQualityCapTakesMinOfReportedAndQuality(t *testing.T) {
	reg := New(testLogger())
	enableQualityCap(t, reg, "")

	// Slow model, provider reports 8 (above its quality batch) -> quality binds at 2.
	loose := makeSchedulerProvider(t, reg, "loose", gemmaBuild, 23)
	loose.mu.Lock()
	loose.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 500_000
	loose.BackendCapacity.Slots[0].MaxConcurrency = 8
	loose.mu.Unlock()
	if got := effCap(reg, loose, gemmaBuild); got != 2 {
		t.Fatalf("effective cap = %d, want 2 (provider-reported 8 is looser than quality 2 → quality binds)", got)
	}

	// Fast model, provider reports 1 (tighter than its high quality batch) -> 1 binds.
	tight := makeSchedulerProvider(t, reg, "tight", qwenBuild, 57)
	tight.mu.Lock()
	tight.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 500_000
	tight.BackendCapacity.Slots[0].MaxConcurrency = 1
	tight.mu.Unlock()
	if got := effCap(reg, tight, qwenBuild); got != 1 {
		t.Fatalf("effective cap = %d, want 1 (provider-reported 1 is tighter than quality → provider binds)", got)
	}
}

// TestQualityCapSpreadsAndSheds drives the real routing path: with two dedicated
// Gemma boxes capped at 2, filling box A to its cap forces the next request onto
// idle box B; with only a capped box available, the request is rejected for
// capacity (→ the dedicated fast-429 shed upstream) instead of over-admitting.
func TestQualityCapSpreadsAndSheds(t *testing.T) {
	reg := New(testLogger())
	reg.SetDedicatedModels([]string{"gemma-4"})
	enableQualityCap(t, reg, "")

	a := makeSchedulerProvider(t, reg, "gemma-a", gemmaBuild, 23)
	budgetSlot(a, 2.6)

	// Fill box A to its cap (2) with coordinator-tracked pending requests.
	a.AddPending(&PendingRequest{RequestID: "fill-a", Model: gemmaBuild})
	a.AddPending(&PendingRequest{RequestID: "fill-b", Model: gemmaBuild})

	// Only the saturated box exists → no candidate (capacity-rejected, not over-admitted).
	if got := reg.ReserveProvider(gemmaBuild, &PendingRequest{RequestID: "req-shed", Model: gemmaBuild, RequestedMaxTokens: 128}); got != nil {
		t.Fatalf("reserved %q for a Gemma request when the only box was at its cap; want nil (shed)", got.ID)
	}

	// Add an idle box B → the request must land there, not pile onto A.
	b := makeSchedulerProvider(t, reg, "gemma-b", gemmaBuild, 23)
	budgetSlot(b, 2.6)
	got := reg.ReserveProvider(gemmaBuild, &PendingRequest{RequestID: "req-spread", Model: gemmaBuild, RequestedMaxTokens: 128})
	if got == nil {
		t.Fatal("ReserveProvider returned nil with an idle box available")
	}
	if got.ID != b.ID {
		t.Fatalf("selected %q, want idle box %q (load must spread, not concentrate on the capped box)", got.ID, b.ID)
	}
}

// TestQualityCapAppliedAtAdmitRecheck: the FINAL admit re-check (providerCanAdmitLockedEx,
// used by ReserveProviderEx after selection) must apply the quality cap too — otherwise
// a heartbeat that bumps load between snapshot and reservation lets a box past its
// quality cap be over-admitted via the legacy flat-cap re-check (TOCTOU).
func TestQualityCapAppliedAtAdmitRecheck(t *testing.T) {
	reg := New(testLogger())
	reg.SetDedicatedModels([]string{"gemma-4"})
	enableQualityCap(t, reg, "")
	p := makeSchedulerProvider(t, reg, "gemma", gemmaBuild, 23)
	budgetSlot(p, 2.6)

	admit := func() bool {
		reg.mu.RLock()
		defer reg.mu.RUnlock()
		p.mu.Lock()
		defer p.mu.Unlock()
		return reg.providerCanAdmitLockedEx(p, gemmaBuild, RequestTraits{}, false, false)
	}

	// Under the cap (1 in flight, cap 2) → admit re-check passes.
	p.AddPending(&PendingRequest{RequestID: "a", Model: gemmaBuild})
	if !admit() {
		t.Fatal("admit re-check rejected a box below its quality cap (1 < 2)")
	}
	// At the cap (2 in flight) → admit re-check must reject (not the flat 24).
	p.AddPending(&PendingRequest{RequestID: "b", Model: gemmaBuild})
	if admit() {
		t.Fatal("admit re-check admitted a box already at its quality cap (2); final re-check must apply the cap")
	}
}

// TestQualityCapDefaultOvercommitIgnoresStaleConfigFallback pins the default
// change: main.go still passes config.ReadConfig's legacy 2.0 fallback when
// EIGENINFERENCE_QUALITY_CONCURRENCY_OVERCOMMIT is unset, and
// SetQualityConcurrencyCap must override that stale argument with the package
// default (1.2) — otherwise the production default silently stays 2.0.
func TestQualityCapDefaultOvercommitIgnoresStaleConfigFallback(t *testing.T) {
	t.Setenv(env.EnvPrefix+"_QUALITY_CONCURRENCY_OVERCOMMIT", "")
	reg := New(testLogger())
	reg.SetQualityConcurrencyCap(true, 2.0, 15, 4) // exactly main.go's call with the env unset

	fast := makeSchedulerProvider(t, reg, "fast", qwenBuild, 57)
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
			reg := New(testLogger())
			enableQualityCap(t, reg, tc.overcommitEnv)
			p := makeSchedulerProvider(t, reg, "box", gemmaBuild, tc.solo)
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
	reg := New(testLogger())
	enableQualityCap(t, reg, "2.0")

	gemma := makeSchedulerProvider(t, reg, "gemma-box", gemmaBuild, 30)
	budgetSlot(gemma, 0)
	qwen := makeSchedulerProvider(t, reg, "qwen-box", qwenBuild, 30)
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
	reg := New(testLogger())
	enableQualityCap(t, reg, "")

	p := makeSchedulerProvider(t, reg, "fast", qwenBuild, 57)
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
	reg := New(testLogger())
	enableQualityCap(t, reg, "")

	slow := makeSchedulerProvider(t, reg, "slow", gemmaBuild, 23) // qc 1
	budgetSlot(slow, 0)
	if got := effCap(reg, slow, gemmaBuild); got != 1 {
		t.Fatalf("cap = %d, want 1 (ceil(qc 1 × 0.01) clamps to 1, never 0)", got)
	}

	tight := makeSchedulerProvider(t, reg, "tight", qwenBuild, 57) // quality would allow 12
	tight.mu.Lock()
	tight.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 500_000
	tight.BackendCapacity.Slots[0].MaxConcurrency = 1
	tight.mu.Unlock()
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
	reg := New(testLogger())
	enableQualityCap(t, reg, "")

	bound := floor / maxOvercommitDilution(effectiveTPSLoadFactor, defaultQualityCapOvercommit)
	for i, solo := range []float64{20, 23, 30, 45, 57, 80, 100} {
		p := makeSchedulerProvider(t, reg, fmt.Sprintf("box-%d", i), gemmaBuild, solo)
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
	diluted := New(testLogger())
	enableQualityCap(t, diluted, "2.0")
	p := makeSchedulerProvider(t, diluted, "diluted", gemmaBuild, 57)
	budgetSlot(p, 0)
	admitted := effCap(diluted, p, gemmaBuild)
	projected := 57 / (1 + effectiveTPSLoadFactor*float64(admitted))
	if projected >= bound {
		t.Fatalf("overcommit 2.0 projects %.2f tok/s at cap %d — expected below the %.2f bar the 1.2 default enforces", projected, admitted, bound)
	}
}

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
	run := func(t *testing.T, seedGemma func(reg *Registry)) {
		reg := New(testLogger())
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
		run(t, func(reg *Registry) {
			for _, v := range []float64{12, 13, 14, 15, 16} {
				reg.tpsRegistry.RecordSolo(gemmaBuild, "M3|Max", v)
			}
		})
	})
	t.Run("seed_env_cold_start", func(t *testing.T) {
		run(t, func(reg *Registry) {
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
	reg := New(testLogger())
	enablePerModelQualityCap(t, reg, gemmaBuild+"=14", "", "")
	p := mixedBoxProvider(t, reg, "unsampled-slow-class", 93)
	p.mu.Lock()
	p.Hardware.ChipFamily = "M2"
	p.Hardware.ChipTier = "Pro"
	p.mu.Unlock()

	for i := 0; i < qualityCapSoloMinSamples; i++ {
		reg.tpsRegistry.RecordSolo(gemmaBuild, "M4|Max", 40)
	}

	if got := resolveSolo(reg, p, gemmaBuild); got.tps != 14 || !got.perModel {
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
	reg := New(testLogger())
	enablePerModelQualityCap(t, reg, gemmaBuild+"=14", "false", "")
	for range 10 {
		reg.tpsRegistry.RecordSolo(gemmaBuild, "M3|Max", 14)
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
	reg := New(testLogger())
	enablePerModelQualityCap(t, reg, "", "", "")
	for i := 0; i < 5; i++ {
		reg.tpsRegistry.RecordSolo(gemmaBuild, "M3|Max", 14)
	}

	mkNoBenchmark := func(id string) *Provider {
		p := mixedBoxProvider(t, reg, id, 0) // DecodeTPS unset
		p.mu.Lock()
		p.Hardware.MemoryBandwidthGBs = 800 // sqrt(800) ≈ 28 fallback
		p.mu.Unlock()
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

// TestQualityConcurrencyMatchesDefiningInequality is the one place the closed
// form is pinned: floor((solo/floor - 1)/k) must agree with a search over the
// inequality it was solved from, across the whole realistic rate range and both
// sides of every clamp. Boundary rates (where the real-valued batch lands on an
// integer) are skipped — there the two derivations legitimately differ by one
// float ulp, and pinning ulps is not a contract.
func TestQualityConcurrencyMatchesDefiningInequality(t *testing.T) {
	const floor = 15.0
	for _, k := range []float64{0.27, effectiveTPSLoadFactor, 0.39, 0.5} {
		for _, limit := range []int{1, 4, 8, 24, 32} {
			for solo := 1.0; solo <= 200.0; solo += 0.25 {
				if b := (solo/floor - 1) / k; math.Abs(b-math.Round(b)) < 1e-9 {
					continue
				}
				want := strictQualityBatch(solo, floor, k, limit)
				if got := qualityConcurrency(solo, floor, k, limit, 4); got != want {
					t.Fatalf("qualityConcurrency(solo=%.2f, floor=%.0f, k=%.2f, limit=%d) = %d, want %d (largest B with solo/(1+k·B) ≥ floor)",
						solo, floor, k, limit, got, want)
				}
			}
		}
	}
	// The batch it returns must actually hold the floor whenever the model can
	// (the clamp-to-1 case is the documented exception: a provider is never
	// fully closed).
	for _, solo := range []float64{16, 20, 23, 30, 57, 93, 99.5, 101.8} {
		b := qualityConcurrency(solo, floor, effectiveTPSLoadFactor, 32, 4)
		if rate := solo / (1 + effectiveTPSLoadFactor*float64(b)); b > 1 && rate < floor {
			t.Fatalf("solo %.1f: quality batch %d projects %.2f tok/s, below the %.0f floor it is defined to hold", solo, b, rate, floor)
		}
	}
}

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

			mk := func(reg *Registry, id string, solo float64) *Provider {
				p := makeSchedulerProvider(t, reg, id, gemmaBuild, solo)
				p.mu.Lock()
				p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 500_000
				p.BackendCapacity.Slots[0].MaxConcurrency = base
				p.mu.Unlock()
				return p
			}

			reg := New(testLogger())
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
	mk := func(t *testing.T, reg *Registry) *Provider {
		p := mixedBoxProvider(t, reg, "v0.8.0-box", 93)
		p.mu.Lock()
		for i := range p.BackendCapacity.Slots {
			if p.BackendCapacity.Slots[i].Model == gemmaBuild {
				p.BackendCapacity.Slots[i].MaxConcurrency = 8
			}
		}
		p.mu.Unlock()
		return p
	}

	t.Run("reported_eight_alone_is_not_enough", func(t *testing.T) {
		reg := New(testLogger())
		enablePerModelQualityCap(t, reg, gemmaBuild+"="+fmt.Sprint(starvedSoloTPS), "", "")
		if got := effCapResolved(reg, mk(t, reg), gemmaBuild); got != 2 {
			t.Fatalf("cap = %d, want 2: a provider-reported 8 is only the MIN's base operand; the %.0f tok/s solo rate decides", got, starvedSoloTPS)
		}
	})

	t.Run("per_model_overcommit_reaches_eight_but_voids_the_bar", func(t *testing.T) {
		reg := New(testLogger())
		t.Setenv(qualityCapOvercommitByModelEnv, gemmaBuild+"=7.5")
		enablePerModelQualityCap(t, reg, gemmaBuild+"="+fmt.Sprint(starvedSoloTPS), "", "")
		got := effCapResolved(reg, mk(t, reg), gemmaBuild)
		if got != 8 {
			t.Fatalf("per-model overcommit 7.5: cap = %d, want 8 (the override plumbing must be config-only)", got)
		}
		// Anything at or under 7 leaves the quality batch of 1 short of 8, so
		// this route has no setting that both reaches 8 and stays an allowance.
		reg7 := New(testLogger())
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
		reg := New(testLogger())
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

// TestWarmTargetDedicatedWholePool: for a dedicated model UNDER DEMAND the
// warm-pool target is the entire eligible pool (warm + eligibleCold), so idle
// dedicated boxes get warmed. With NO demand for that build it is left at the
// demand-derived count (so an idle/stale build — e.g. the previous build during
// an alias migration — is not force-warmed across the whole pool). A
// non-dedicated model with no pressure is left at its current warm count.
func TestWarmTargetDedicatedWholePool(t *testing.T) {
	reg := New(testLogger())
	reg.SetDedicatedModels([]string{"gemma-4"})
	c := newWarmPoolController(reg, WarmPoolConfig{
		DecodeFloorTPS:             15,
		FallbackQualityConcurrency: 4,
		BurstBuffer:                1,
		AssumedPromptTokens:        512,
		AssumedCompletionTokens:    256,
		// Realistic pressure thresholds (≥1) so a zero-pressure snapshot registers NO
		// demand pressure — otherwise the 0>=0 default makes every model look pressured.
		CapacityRejectThreshold:   1,
		TTFTMissThreshold:         1,
		ColdDispatchThreshold:     1,
		SpeculativeStartThreshold: 1,
		SpeculativeWinThreshold:   1,
		WarmSaturationThreshold:   0.8,
	})
	params := c.targetParams()
	now := time.Now()

	dedicated := warmPoolModelSnapshot{
		model:         gemmaBuild,
		warm:          2,
		soloDecodeTPS: 23,
		prefillTPS:    276,
		eligibleCold: []warmPoolCandidate{
			{providerID: "c1"}, {providerID: "c2"}, {providerID: "c3"},
		},
	}
	svc := estimateServiceTime(dedicated.prefillTPS, dedicated.soloDecodeTPS, params)
	// Under demand (a capacity reject) → warm the whole eligible pool (2 + 3 = 5).
	underDemand := warmPoolPressureBucket{capacityRejects: 1}
	if got := c.targetWarm(dedicated, underDemand, warmPoolQueuePressure{}, params, svc, now); got != 5 {
		t.Fatalf("dedicated (under demand) warm target = %d, want 5 (warm 2 + eligibleCold 3 = whole pool)", got)
	}
	// No demand for this build → NOT force-warmed across the pool (left demand-derived).
	if got := c.targetWarm(dedicated, warmPoolPressureBucket{}, warmPoolQueuePressure{}, params, svc, now); got == 5 {
		t.Fatalf("dedicated (no demand) warm target = %d, want < 5 (idle/stale build must not force-warm the whole pool)", got)
	}

	nonDedicated := warmPoolModelSnapshot{
		model:         qwenBuild,
		warm:          2,
		soloDecodeTPS: 57,
		prefillTPS:    684,
		eligibleCold:  []warmPoolCandidate{{providerID: "c1"}, {providerID: "c2"}, {providerID: "c3"}},
	}
	svc2 := estimateServiceTime(nonDedicated.prefillTPS, nonDedicated.soloDecodeTPS, params)
	if got := c.targetWarm(nonDedicated, warmPoolPressureBucket{}, warmPoolQueuePressure{}, params, svc2, now); got != 2 {
		t.Fatalf("non-dedicated warm target = %d, want 2 (no demand pressure → left as-is)", got)
	}
}

// TestQualityCapPrefersMeasuredSoloRateOverProxyAndSeed pins the DURABLE fix
// for the B=8 shortfall, and the reason the shortfall existed.
//
// Production shape, reproduced exactly here: gemma-4 is a DEDICATED model
// (EIGENINFERENCE_DEDICATED_MODELS=gemma-4), and the Swift provider never
// sends decode_tps at registration — the field exists on RegisterMessage and
// is encoded, but nothing in provider-swift/Sources ever assigns it. So
// p.DecodeTPS == 0, the dedicated guard in
// effectiveMaxConcurrencyForModelRateLocked does NOT hold the model to its
// reported base, and the rate reaching qualityConcurrency is
// resolvedDecodeTPS's sqrt(memory_bandwidth) — a MODEL-AGNOSTIC hardware proxy
// (20 tok/s at the 400 GB/s test fixture, ~23 on a real 546 GB/s M4 Max)
// against a measured ~99.5 tok/s. Raising engine_v2_max_concurrent to 8 buys
// nothing against that.
//
// The provider is NOT silent about its real rate: it reports the measured
// per-model EWMA in observed_decode_tps on every heartbeat
// (EngineV2Bridge+Capacity.swift populates it from
// EngineV2Bridge.observedDecodeTpsEwma), and the heartbeat ingest already
// converts the uncontended ones into solo samples. The only thing standing
// between that measurement and the cap was the qualityCapSoloMinSamples floor:
// under 5 samples the chain skipped straight past a real, solo-gated,
// per-model measurement to the hardware proxy. It now prefers the measurement.
func TestQualityCapPrefersMeasuredSoloRateOverProxyAndSeed(t *testing.T) {
	const floor = 15.0
	const base = 8
	// The CBv2 v2-paged B=1 per-request decode rate for gemma-4-26b-qat-4bit on
	// an M4 Max — the shipping engine's own, conservative number (eager measures
	// 101.8):
	// libs/mlx-swift-lm/benchmarks/reports/gemma4-26b-qat4bit-paged-gate-2026-07-09.md
	const measuredGemmaSoloTPS = 99.5
	// The starved seed the pre-fix chain was stuck with, standing in for the
	// sqrt-bandwidth proxy: both land at or under the floor.
	const starvedSeedTPS = 14.0

	// threshold is the solo rate at which a provider reporting `base` is granted
	// all of it, derived from (floor, k, overcommit) rather than hard-coded.
	threshold := soloTPSForCap(floor, base, defaultQualityCapOvercommit)

	// prodBox is the production shape: dedicated model, NO registration
	// benchmark, provider-reported concurrency of 8.
	prodBox := func(t *testing.T, reg *Registry) *Provider {
		reg.SetDedicatedModels([]string{"gemma-4"})
		return makeSchedulerProvider(t, reg, "prod-box", gemmaBuild, 0)
	}
	// slot is the heartbeat slot the provider sends. observedTPS <= 0 models a
	// provider that has completed no request: observedDecodeTpsEwma is still 0,
	// `observed_decode_tps` is omitempty, so the field is absent on the wire.
	slot := func(observedTPS float64, numRunning int) protocol.BackendSlotCapacity {
		return protocol.BackendSlotCapacity{
			Model:                gemmaBuild,
			State:                "running",
			NumRunning:           numRunning,
			MaxConcurrency:       base,
			ActiveTokenBudgetMax: 500_000,
			ObservedDecodeTPS:    observedTPS,
		}
	}
	// observe drives the REAL heartbeat ingest path n times — the same
	// soloSampleEligible + NumRunning > 0 gate production uses, not a direct
	// tpsRegistry poke.
	observe := func(reg *Registry, n int, tps float64) {
		for range n {
			reg.Heartbeat("prod-box", soloHeartbeat([]protocol.BackendSlotCapacity{slot(tps, 1)}))
		}
	}

	// --- The arithmetic the fix has to clear ---------------------------------
	//
	// effectiveTPSLoadFactor was re-fitted 0.27 -> 0.39, which RAISES the solo
	// rate needed for cap 8 from ~39.3 to ~50.1 tok/s. Assert the derived
	// threshold really is that, then assert the measured rate clears it with
	// close to 2x margin — the fix must not be resting on a rounding edge.
	t.Run("measured_rate_clears_the_refitted_threshold_with_margin", func(t *testing.T) {
		if effectiveTPSLoadFactor != 0.39 {
			t.Fatalf("k = %.2f, expected the re-fitted 0.39 — the margins below are stated against it", effectiveTPSLoadFactor)
		}
		if math.Abs(threshold-50.1) > 0.5 {
			t.Fatalf("derived cap-8 threshold = %.2f tok/s, expected ~50.1 at floor %.0f / k %.2f / overcommit %.1f",
				threshold, floor, effectiveTPSLoadFactor, defaultQualityCapOvercommit)
		}
		if margin := measuredGemmaSoloTPS / threshold; margin < 1.9 {
			t.Fatalf("measured %.1f tok/s is only %.2fx the %.2f tok/s cap-8 threshold — want >= 1.9x real margin",
				measuredGemmaSoloTPS, margin, threshold)
		}
		// Granted on QUALITY, not bought with the overcommit allowance: the
		// strict quality batch alone reaches base, and the projected
		// per-request rate at B=8 stays at or above the floor.
		if qc := strictQualityBatch(measuredGemmaSoloTPS, floor, effectiveTPSLoadFactor, base); qc != base {
			t.Fatalf("strict quality batch at the measured rate = %d, want %d — cap 8 must not depend on overcommit rounding", qc, base)
		}
		if projected := measuredGemmaSoloTPS / (1 + effectiveTPSLoadFactor*base); projected < floor {
			t.Fatalf("projected per-request decode at B=8 is %.2f tok/s, below the %.0f floor", projected, floor)
		}
	})

	// --- Cold start: a provider that has served nothing ----------------------
	//
	// This is the case the fallback chain must not break. The provider reports
	// NO observed_decode_tps (the field is absent, not zero-on-the-wire), so no
	// solo sample is ingested, nothing per-model resolves, and the chain lands
	// on the hardware proxy. That must stay a SANE positive cap — the box has
	// to be able to serve in order to ever measure itself.
	t.Run("cold_start_reports_nothing_and_still_gets_a_sane_cap", func(t *testing.T) {
		reg := New(testLogger())
		p := prodBox(t, reg)
		enablePerModelQualityCap(t, reg, "", "", "")
		reg.Heartbeat("prod-box", soloHeartbeat([]protocol.BackendSlotCapacity{slot(0, 0)}))

		if _, n := reg.tpsRegistry.SoloMedian(gemmaBuild, chipClassKey(p.Hardware)); n != 0 {
			t.Fatalf("solo samples from a provider that reported no rate = %d, want 0", n)
		}
		rate := resolveSolo(reg, p, gemmaBuild)
		if rate.perModel {
			t.Fatalf("cold start resolved a per-model rate (%.2f) with no measurement and no seed", rate.tps)
		}
		if rate.tps != resolvedDecodeTPS(p) {
			t.Fatalf("cold-start rate = %.2f, want the provider-level proxy %.2f", rate.tps, resolvedDecodeTPS(p))
		}
		got := effCapResolved(reg, p, gemmaBuild)
		// Pinned as the closed form of the proxy rate, not as a literal: the
		// integer moves with k, the contract ("the proxy's own answer, and it
		// is a servable one") does not.
		if want := wantQualityCap(resolvedDecodeTPS(p), floor, base, defaultQualityCapOvercommit); got != want {
			t.Fatalf("cold-start cap = %d, want %d — the proxy's own derived answer", got, want)
		}
		if got < 2 {
			t.Fatalf("cold-start cap = %d, want >= 2 — a fresh provider must not be strangled to 1 by its own silence; it has to be able to serve in order to ever measure itself", got)
		}
		if got >= base {
			t.Fatalf("cold-start cap = %d, want < %d: with no measurement the proxy must NOT grant the full bump", got, base)
		}
	})

	// --- The fix: one measured, solo-gated sample is enough ------------------
	t.Run("one_measured_sample_under_the_floor_reaches_eight", func(t *testing.T) {
		reg := New(testLogger())
		p := prodBox(t, reg)
		enablePerModelQualityCap(t, reg, "", "", "")

		// Pre-fix baseline, same registry: the proxy caps this box at 2.
		if got := effCapResolved(reg, p, gemmaBuild); got >= base {
			t.Fatalf("before any measurement the cap is %d — the proxy baseline this test contrasts against is gone", got)
		}

		observe(reg, 1, measuredGemmaSoloTPS)

		_, n := reg.tpsRegistry.SoloMedian(gemmaBuild, chipClassKey(p.Hardware))
		if n != 1 {
			t.Fatalf("solo samples = %d, want exactly 1", n)
		}
		if n >= qualityCapSoloMinSamples {
			t.Fatalf("test is not exercising the under-sampled path: %d samples meets the %d floor", n, qualityCapSoloMinSamples)
		}
		rate := resolveSolo(reg, p, gemmaBuild)
		if !rate.perModel || math.Abs(rate.tps-measuredGemmaSoloTPS) > 1e-9 {
			t.Fatalf("resolved rate = %+v, want the measured %.1f tok/s tagged per-model", rate, measuredGemmaSoloTPS)
		}
		if got := effCapResolved(reg, p, gemmaBuild); got != base {
			t.Fatalf("cap = %d, want %d: one solo-gated measurement of the real rate must beat the model-agnostic proxy", got, base)
		}
	})

	// A measurement of THIS model on THIS box outranks a fleet-wide configured
	// guess. Ordering is measured -> seed -> proxy; a stale low seed must not
	// hold a box down once it has measured itself.
	t.Run("measured_rate_outranks_a_low_seed", func(t *testing.T) {
		reg := New(testLogger())
		p := prodBox(t, reg)
		enablePerModelQualityCap(t, reg, gemmaBuild+"="+fmt.Sprint(starvedSeedTPS), "", "")

		if got := effCapResolved(reg, p, gemmaBuild); got != 2 {
			t.Fatalf("seed-only cap = %d, want 2 (the starved %.0f tok/s seed)", got, starvedSeedTPS)
		}
		observe(reg, 1, measuredGemmaSoloTPS)
		if got := effCapResolved(reg, p, gemmaBuild); got != base {
			t.Fatalf("cap = %d, want %d: the measured rate must outrank the %.0f tok/s seed", got, base, starvedSeedTPS)
		}
	})

	// The first sample is taken as the box drops to one running request, so the
	// alpha=0.3 EWMA still carries batched history and UNDER-states the solo
	// rate. Worst realistic case is a fully contaminated rate(B=2) reading at
	// the cap gemma is stuck on today. Even that clears the bar — the fix is
	// not resting on a perfectly converged EWMA.
	t.Run("contaminated_first_sample_still_reaches_eight", func(t *testing.T) {
		contended := measuredGemmaSoloTPS / (1 + effectiveTPSLoadFactor*2)
		if contended >= measuredGemmaSoloTPS || contended <= threshold {
			t.Fatalf("rate(B=2) = %.2f tok/s is not a contaminated-but-passing reading against threshold %.2f", contended, threshold)
		}
		reg := New(testLogger())
		p := prodBox(t, reg)
		enablePerModelQualityCap(t, reg, "", "", "")
		observe(reg, 1, contended)
		if got := effCapResolved(reg, p, gemmaBuild); got != base {
			t.Fatalf("cap = %d at a fully B=2-contaminated reading of %.2f tok/s, want %d", got, contended, base)
		}
	})

	// The point is that the cap sees a TRUE rate, not a permissive one. A box
	// that genuinely measures slow is still capped — the fix raises the cap by
	// improving the INPUT, never by relaxing the bar.
	t.Run("a_genuinely_slow_measurement_is_still_capped", func(t *testing.T) {
		slow := 30.0
		if slow >= threshold {
			t.Fatalf("%.1f tok/s is not below the %.2f tok/s threshold; pick a slower rate", slow, threshold)
		}
		reg := New(testLogger())
		p := prodBox(t, reg)
		enablePerModelQualityCap(t, reg, "", "", "")
		observe(reg, 1, slow)
		got := effCapResolved(reg, p, gemmaBuild)
		if got >= base {
			t.Fatalf("cap = %d at a measured %.0f tok/s, want < %d — a slow box must not be granted the bump", got, slow, base)
		}
		if got < 1 {
			t.Fatalf("cap = %d, want >= 1", got)
		}
	})

	// A well-sampled median still outranks a single sample: the relaxation is a
	// FALLBACK below the trusted floors, not a replacement for them.
	t.Run("trusted_median_still_outranks_the_under_sampled_fallback", func(t *testing.T) {
		reg := New(testLogger())
		p := prodBox(t, reg)
		enablePerModelQualityCap(t, reg, "", "", "")
		observe(reg, qualityCapSoloMinSamples, 30.0)
		observe(reg, 1, measuredGemmaSoloTPS)
		_, n := reg.tpsRegistry.SoloMedian(gemmaBuild, chipClassKey(p.Hardware))
		if n < qualityCapSoloMinSamples {
			t.Fatalf("solo samples = %d, want >= the %d floor", n, qualityCapSoloMinSamples)
		}
		rate := resolveSolo(reg, p, gemmaBuild)
		if rate.tps != 30.0 {
			t.Fatalf("resolved rate = %.2f, want the trusted median 30.00 — the single fast sample must not displace it", rate.tps)
		}
	})
}

// A provider at its effective concurrency cap spills to a peer with headroom.
func TestConcurrencyCapSpillsToProviderWithHeadroom(t *testing.T) {
	reg := New(testLogger())
	model := "p2-cap-model"
	reg.SetModelCatalog([]CatalogEntry{{ID: model}})

	schedulerScenarioProvider{id: "ultra", decodeTPS: 100, totalMemGB: 512, gpuActiveGB: 50,
		pending: 12, backendRun: 12}.register(t, reg, model)
	schedulerScenarioProvider{id: "max-128", decodeTPS: 60, totalMemGB: 128, gpuActiveGB: 5}.register(t, reg, model)

	p := reserveSchedulerScenario(reg, model, 256)
	if p == nil {
		t.Fatal("expected fallback to max-128, got nil")
	}
	if p.ID != "max-128" {
		t.Fatalf("got %q, want max-128 because ultra is at its effective cap", p.ID)
	}
}
