package registry

import (
	"testing"
	"time"
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

// TestQualityCapUsesStaticNotObservedTPS is the regression that matters: a slow
// model's box is capped from its STATIC single-stream rate (~23 tok/s → quality
// batch 1 → cap 2 at overcommit 2), and the collapsed observed-under-load EWMA
// (~2.6 tok/s, which would force a cap of 1) must NOT change the result —
// otherwise the cap inherits the very feedback loop it exists to break.
func TestQualityCapUsesStaticNotObservedTPS(t *testing.T) {
	reg := New(testLogger())
	reg.SetQualityConcurrencyCap(true, 2.0, 15, 4)
	p := makeSchedulerProvider(t, reg, "gemma-box", gemmaBuild, 23) // static 23 tok/s
	budgetSlot(p, 2.6)                                              // collapsed observed EWMA

	if got := effCap(reg, p, gemmaBuild); got != 2 {
		t.Fatalf("effective cap = %d, want 2 (quality batch 1 from STATIC 23 tok/s × overcommit 2, ignoring observed 2.6)", got)
	}
}

// TestQualityCapScalesWithModelSpeed shows the cap is universal and self-tuning:
// a fast model (57 tok/s → quality batch 10) keeps a high cap (20) that never
// bites normal load, while a slow model (23 tok/s) is tightened to 2.
func TestQualityCapScalesWithModelSpeed(t *testing.T) {
	reg := New(testLogger())
	reg.SetQualityConcurrencyCap(true, 2.0, 15, 4)

	slow := makeSchedulerProvider(t, reg, "slow", gemmaBuild, 23)
	budgetSlot(slow, 0)
	fast := makeSchedulerProvider(t, reg, "fast", qwenBuild, 57)
	budgetSlot(fast, 0)

	if got := effCap(reg, slow, gemmaBuild); got != 2 {
		t.Fatalf("slow cap = %d, want 2", got)
	}
	if got := effCap(reg, fast, qwenBuild); got != 20 {
		t.Fatalf("fast cap = %d, want 20 (qc 10 × 2, ≤ flat 24) — far above normal load, no regression", got)
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
	reg.SetQualityConcurrencyCap(true, 2.0, 15, 4)

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
	reg.SetQualityConcurrencyCap(true, 2.0, 15, 4)

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

// TestWarmTargetDedicatedWholePool: for a dedicated model the warm-pool target is
// the entire eligible pool (warm + eligibleCold) regardless of demand pressure,
// so idle dedicated boxes get warmed; a non-dedicated model with no pressure is
// left at its current warm count.
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
	if got := c.targetWarm(dedicated, warmPoolPressureBucket{}, warmPoolQueuePressure{}, params, svc, now); got != 5 {
		t.Fatalf("dedicated warm target = %d, want 5 (warm 2 + eligibleCold 3 = whole pool)", got)
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
