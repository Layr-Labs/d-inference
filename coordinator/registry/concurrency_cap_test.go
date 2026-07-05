package registry

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
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
// a fast model (57 tok/s → quality batch 10) keeps a high cap (12 at the default
// 1.2 overcommit) that never bites normal load, while a slow model (23 tok/s) is
// tightened to 2.
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
	if got := effCap(reg, fast, qwenBuild); got != 12 {
		t.Fatalf("fast cap = %d, want 12 (ceil(qc 10 × 1.2), ≤ flat 24) — far above normal load, no regression", got)
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

	fast := makeSchedulerProvider(t, reg, "fast", qwenBuild, 57) // qc 10
	budgetSlot(fast, 0)
	if got := effCap(reg, fast, qwenBuild); got != 12 {
		t.Fatalf("effective cap = %d, want 12 (default 1.2 must apply, not the stale 2.0 config fallback → 20)", got)
	}
}

// TestQualityCapOvercommitDilution is the cap math from the production incident:
// with floor 15 and k = 0.27, overcommit 2.0 admits enough concurrency that the
// projected per-request decode rate (solo/(1+k·B) at B = cap) collapses to
// roughly HALF the floor on fast boxes, while 1.2 keeps it within the overcommit
// allowance of the floor.
func TestQualityCapOvercommitDilution(t *testing.T) {
	cases := []struct {
		name          string
		overcommitEnv string
		solo          float64
		wantCap       int
	}{
		{"gemma23_at_1.2", "1.2", 23, 2}, // qc 1 → ceil(1.2)
		{"gemma23_at_2.0", "2.0", 23, 2}, // qc 1 → ceil(2.0)
		{"solo30_at_1.2", "1.2", 30, 4},  // qc 3 → ceil(3.6)
		{"solo30_at_2.0", "2.0", 30, 6},  // qc 3 → 6
		{"solo57_at_1.2", "1.2", 57, 12}, // qc 10 → 12
		{"solo57_at_2.0", "2.0", 57, 20}, // qc 10 → 20
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			reg := New(testLogger())
			enableQualityCap(t, reg, tc.overcommitEnv)
			p := makeSchedulerProvider(t, reg, "box", gemmaBuild, tc.solo)
			budgetSlot(p, 0)
			got := effCap(reg, p, gemmaBuild)
			if got != tc.wantCap {
				t.Fatalf("solo %.0f tok/s at overcommit %s: cap = %d, want %d", tc.solo, tc.overcommitEnv, got, tc.wantCap)
			}
			// The dilution difference in decode terms: projected per-request TPS
			// once the box is filled to its cap.
			projected := tc.solo / (1 + effectiveTPSLoadFactor*float64(got))
			if tc.overcommitEnv == "2.0" && tc.solo == 57 && projected >= 15.0*0.6 {
				t.Fatalf("overcommit 2.0 on a 57 tok/s box projects %.1f tok/s at cap %d — expected roughly half the 15 floor", projected, got)
			}
			if tc.overcommitEnv == "1.2" && projected < 15.0/1.2-1e-9 {
				t.Fatalf("overcommit 1.2 on a %.0f tok/s box projects %.1f tok/s at cap %d — must stay ≥ floor/1.2 (%.2f)", tc.solo, projected, got, 15.0/1.2)
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

	gemma := makeSchedulerProvider(t, reg, "gemma-box", gemmaBuild, 30) // qc 3
	budgetSlot(gemma, 0)
	qwen := makeSchedulerProvider(t, reg, "qwen-box", qwenBuild, 30) // qc 3
	budgetSlot(qwen, 0)

	if got := effCap(reg, gemma, gemmaBuild); got != 3 {
		t.Fatalf("override model cap = %d, want 3 (per-model overcommit 1.0 × qc 3, uppercase key must match)", got)
	}
	if got := effCap(reg, qwen, qwenBuild); got != 6 {
		t.Fatalf("non-override model cap = %d, want 6 (malformed entry skipped → global overcommit 2.0 × qc 3)", got)
	}
}

// TestQualityCapPerModelOverrideAbsentUsesGlobalDefault: with an override map
// that does not mention the model and no global env set, the model uses the
// package default (1.2).
func TestQualityCapPerModelOverrideAbsentUsesGlobalDefault(t *testing.T) {
	t.Setenv(qualityCapOvercommitByModelEnv, "some-other-model=1.0")
	reg := New(testLogger())
	enableQualityCap(t, reg, "")

	p := makeSchedulerProvider(t, reg, "fast", qwenBuild, 57) // qc 10
	budgetSlot(p, 0)
	if got := effCap(reg, p, qwenBuild); got != 12 {
		t.Fatalf("cap = %d, want 12 (no per-model entry → default 1.2 × qc 10)", got)
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
// guarantee of the new default: at overcommit 1.2, a provider filled to its
// admitted cap projects per-request decode (rate(B) = solo/(1+k·B), the same
// degradation model the package routes with) no lower than floor/1.2 —
// i.e. the 15 tok/s floor holds within the overcommit allowance across the
// realistic solo-rate range, where the old 2.0 default let it collapse to
// roughly half the floor.
func TestQualityCapProjectedDecodeTPSAtDefaultHoldsNearFloor(t *testing.T) {
	const floor = 15.0
	reg := New(testLogger())
	enableQualityCap(t, reg, "")

	for i, solo := range []float64{20, 23, 30, 45, 57, 80, 100} {
		p := makeSchedulerProvider(t, reg, fmt.Sprintf("box-%d", i), gemmaBuild, solo)
		budgetSlot(p, 0)
		admitted := effCap(reg, p, gemmaBuild)
		projected := solo / (1 + effectiveTPSLoadFactor*float64(admitted))
		if projected < floor/defaultQualityCapOvercommit-1e-9 {
			t.Errorf("solo %.0f tok/s: cap %d projects %.2f tok/s — below floor/overcommit (%.2f)",
				solo, admitted, projected, floor/defaultQualityCapOvercommit)
		}
	}

	// Contrast with the old default: 2.0 admits 20 concurrent on a 57 tok/s box,
	// projecting ~8.9 tok/s — the below-floor dilution the new default removes.
	diluted := New(testLogger())
	enableQualityCap(t, diluted, "2.0")
	p := makeSchedulerProvider(t, diluted, "diluted", gemmaBuild, 57)
	budgetSlot(p, 0)
	admitted := effCap(diluted, p, gemmaBuild)
	projected := 57 / (1 + effectiveTPSLoadFactor*float64(admitted))
	if projected >= floor/defaultQualityCapOvercommit {
		t.Fatalf("overcommit 2.0 projects %.2f tok/s at cap %d — expected below the floor/1.2 bar the new default enforces", projected, admitted)
	}
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
