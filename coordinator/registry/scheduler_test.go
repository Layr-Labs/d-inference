package registry

import (
	"testing"
	"time"
)

func TestReserveProviderSkipsSelfSigned(t *testing.T) {
	reg := New(testLogger())
	model := "scheduler-model"
	hw := makeSchedulerProvider(t, reg, "hardware", model, 80)
	self := makeSchedulerProvider(t, reg, "self", model, 200)

	self.mu.Lock()
	self.TrustLevel = TrustSelfSigned
	self.mu.Unlock()

	req := &PendingRequest{
		RequestID:          "req-1",
		Model:              model,
		RequestedMaxTokens: 128,
	}
	selected := reg.ReserveProvider(model, req)
	if selected == nil {
		t.Fatal("ReserveProvider returned nil")
	}
	if selected.ID != hw.ID {
		t.Fatalf("selected %q, want %q", selected.ID, hw.ID)
	}
}

func TestReserveProviderExReturnsCostBreakdown(t *testing.T) {
	reg := New(testLogger())
	model := "decision-model"
	makeSchedulerProvider(t, reg, "p1", model, 100)
	makeSchedulerProvider(t, reg, "p2", model, 80)

	req := &PendingRequest{
		RequestID:             "req-decision",
		Model:                 model,
		EstimatedPromptTokens: 100,
		RequestedMaxTokens:    256,
	}
	provider, decision := reg.ReserveProviderEx(model, req)
	if provider == nil {
		t.Fatal("ReserveProviderEx returned nil provider")
	}
	if decision.ProviderID != provider.ID {
		t.Fatalf("decision.ProviderID=%q, want %q", decision.ProviderID, provider.ID)
	}
	if decision.Model != model {
		t.Fatalf("decision.Model=%q, want %q", decision.Model, model)
	}
	if decision.CandidateCount != 2 {
		t.Fatalf("decision.CandidateCount=%d, want 2", decision.CandidateCount)
	}
	if decision.CostMs <= 0 {
		t.Fatalf("decision.CostMs=%f, want > 0", decision.CostMs)
	}
	// ThisReqMs must be the dominant term for an idle provider with no backlog
	// (decode 256 tokens / 100 TPS = 2560ms; prefill 100 / 400 = 250ms).
	if decision.ThisReqMs < 2500 {
		t.Fatalf("decision.ThisReqMs=%f, expected ~2810ms", decision.ThisReqMs)
	}
	// Sum of components should approximately equal the total cost.
	sum := decision.StateMs + decision.QueueMs + decision.PendingMs +
		decision.BacklogMs + decision.ThisReqMs + decision.HealthMs + decision.CapacityRateMs
	if diff := sum - decision.CostMs; diff > 0.001 || diff < -0.001 {
		t.Fatalf("breakdown sum %f != CostMs %f", sum, decision.CostMs)
	}
}

func TestQuickCapacityCheckWithTTFTEstimatesBestEligibleProvider(t *testing.T) {
	reg := New(testLogger())
	model := "ttft-model"
	slow := makeSchedulerProvider(t, reg, "slow", model, 100)
	slow.mu.Lock()
	// Pin the prefill rate (== old decodeTPS*4 fallback) so the TTFT queue-math
	// assertions here are independent of the tunable decode→prefill fallback ratio.
	slow.PrefillTPS = 400
	slow.BackendCapacity.Slots[0].NumWaiting = 100
	slow.BackendCapacity.Slots[0].MaxConcurrency = 128
	slow.mu.Unlock()

	candidates, rejections, tooLarge, bestTTFT, hasTTFT := reg.QuickCapacityCheckWithTTFTForRequest(model, 100, 128, RequestTraits{}, false)
	if candidates != 1 || rejections != 0 || tooLarge != 0 {
		t.Fatalf("capacity = (%d,%d,%d), want (1,0,0)", candidates, rejections, tooLarge)
	}
	if !hasTTFT || bestTTFT <= 10*time.Second {
		t.Fatalf("bestTTFT = %v has=%v, want above 10s with backlog", bestTTFT, hasTTFT)
	}

	fast := makeSchedulerProvider(t, reg, "fast", model, 100)
	fast.mu.Lock()
	fast.PrefillTPS = 400
	fast.mu.Unlock()
	candidates, rejections, tooLarge, bestTTFT, hasTTFT = reg.QuickCapacityCheckWithTTFTForRequest(model, 100, 128, RequestTraits{}, false)
	if candidates != 2 || rejections != 0 || tooLarge != 0 {
		t.Fatalf("capacity with fast provider = (%d,%d,%d), want (2,0,0)", candidates, rejections, tooLarge)
	}
	if !hasTTFT || bestTTFT >= 10*time.Second {
		t.Fatalf("bestTTFT = %v has=%v, want under 10s from fast provider", bestTTFT, hasTTFT)
	}
}

func TestQuickCapacityCheckWithTTFTIncludesWaitingPrefills(t *testing.T) {
	reg := New(testLogger())
	model := "ttft-waiting-prefill-model"
	p := makeTokenBudgetProvider(t, reg, "budget", model, 100, 20_000, 100_000, 100)
	p.mu.Lock()
	// Pin the prefill rate (== old decodeTPS*4 fallback) so this waiting-prefill
	// TTFT assertion is independent of the tunable decode→prefill fallback ratio.
	p.PrefillTPS = 400
	p.BackendCapacity.Slots[0].NumWaiting = 3
	p.BackendCapacity.Slots[0].MaxConcurrency = 8
	p.BackendCapacity.Slots[0].QueuedTokenBudget = 40_000
	p.mu.Unlock()

	candidates, rejections, tooLarge, bestTTFT, hasTTFT := reg.QuickCapacityCheckWithTTFTForRequest(model, 2_000, 128, RequestTraits{}, false)
	if candidates != 1 || rejections != 0 || tooLarge != 0 {
		t.Fatalf("capacity = (%d,%d,%d), want (1,0,0)", candidates, rejections, tooLarge)
	}
	if !hasTTFT || bestTTFT < 20*time.Second || bestTTFT > 21*time.Second {
		t.Fatalf("bestTTFT = %v has=%v, want about 20s from waiting prefills plus this prefill", bestTTFT, hasTTFT)
	}
}

func TestQuickCapacityCheckWithTTFTIgnoresActiveReservations(t *testing.T) {
	reg := New(testLogger())
	model := "ttft-active-reservation-model"
	p := makeTokenBudgetProvider(t, reg, "running", model, 100, 80_000, 200_000, 100)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].NumRunning = 1
	p.BackendCapacity.Slots[0].MaxTokensPotential = 100_000
	p.BackendCapacity.Slots[0].QueuedTokenBudget = 40_000
	p.mu.Unlock()

	candidates, rejections, tooLarge, bestTTFT, hasTTFT := reg.QuickCapacityCheckWithTTFTForRequest(model, 100, 2048, RequestTraits{}, false)
	if candidates != 1 || rejections != 0 || tooLarge != 0 {
		t.Fatalf("capacity = (%d,%d,%d), want (1,0,0)", candidates, rejections, tooLarge)
	}
	if !hasTTFT || bestTTFT > time.Second {
		t.Fatalf("bestTTFT = %v has=%v, want active reservations not to inflate first-token estimate", bestTTFT, hasTTFT)
	}
}

func TestResolvedPrefillTPSFallbackRatio(t *testing.T) {
	// A provider-reported prefill rate always wins.
	if got := resolvedPrefillTPS(&Provider{PrefillTPS: 500, DecodeTPS: 50}); got != 500 {
		t.Fatalf("reported prefill = %v, want 500", got)
	}

	// Without a reported rate, fall back to decodeTPS * the configured ratio
	// (default 12) — not the old 4x, which under-estimated prefill ~3x and made
	// the TTFT gate reject warm providers above ~550 prompt tokens.
	noReport := &Provider{DecodeTPS: 50}
	if got, want := resolvedPrefillTPS(noReport), 50*defaultPrefillToDecodeRatio; got != want {
		t.Fatalf("fallback prefill = %v, want %v", got, want)
	}

	// Overrides are honored; non-positive values are ignored.
	orig := prefillToDecodeRatio
	defer func() { prefillToDecodeRatio = orig }()
	SetPrefillToDecodeRatio(20)
	if got := resolvedPrefillTPS(noReport); got != 50*20 {
		t.Fatalf("overridden prefill = %v, want 1000", got)
	}
	SetPrefillToDecodeRatio(0)
	SetPrefillToDecodeRatio(-5)
	if got := resolvedPrefillTPS(noReport); got != 50*20 {
		t.Fatalf("prefill after ignored non-positive overrides = %v, want 1000", got)
	}
}

func TestResolvePrefillTPSPrefersObserved(t *testing.T) {
	// No measured rate: the resolver returns the existing prefillTPS chain
	// (resolvedPrefillTPS: benchmark → decode×12) unchanged. This is the
	// today-fleet path and MUST be a no-op.
	if got := resolvePrefillTPS(routingSnapshot{prefillTPS: 600}); got != 600 {
		t.Fatalf("fallback prefill = %v, want 600 (×12 chain preserved)", got)
	}
	// A non-positive observed value is treated as unmeasured → fallback.
	if got := resolvePrefillTPS(routingSnapshot{prefillTPS: 600, observedPrefillTPS: 0}); got != 600 {
		t.Fatalf("zero observed prefill = %v, want 600 (fallback)", got)
	}
	// A measured per-slot prefill EWMA wins over the static chain.
	if got := resolvePrefillTPS(routingSnapshot{prefillTPS: 600, observedPrefillTPS: 1800}); got != 1800 {
		t.Fatalf("observed prefill = %v, want 1800 (measured preferred)", got)
	}
	// The result is clamped to maxPrefillTPS so one outlier heartbeat cannot
	// collapse the TTFT estimate.
	if got := resolvePrefillTPS(routingSnapshot{observedPrefillTPS: maxPrefillTPS * 2}); got != maxPrefillTPS {
		t.Fatalf("clamped observed prefill = %v, want %v", got, maxPrefillTPS)
	}
}

func TestTTFTMsFromSnapshotUsesObservedPrefillTPS(t *testing.T) {
	const prompt = 1000
	// Fallback path: no measured prefill → ttft uses snap.prefillTPS (the ×12
	// chain), identical to the pre-wiring behavior. statePenalty(running)=0,
	// queuedPrefill=0, firstDecode=1000/decode.
	fallback := routingSnapshot{
		hasBackendCapacity: true,
		slotState:          "running",
		prefillTPS:         600, // e.g. decode 50 × 12
		decodeTPS:          50,
	}
	fallbackTTFT := ttftMsFromSnapshot(fallback, prompt)
	wantFallback := float64(prompt)/600*1000 + 1000.0/50.0
	if d := fallbackTTFT - wantFallback; d > 0.01 || d < -0.01 {
		t.Fatalf("fallback TTFT = %.4f, want %.4f (×12 chain preserved)", fallbackTTFT, wantFallback)
	}

	// Measured path: a 3× faster observed prefill lowers only the prefill term.
	observed := fallback
	observed.observedPrefillTPS = 1800
	observedTTFT := ttftMsFromSnapshot(observed, prompt)
	wantObserved := float64(prompt)/1800*1000 + 1000.0/50.0
	if d := observedTTFT - wantObserved; d > 0.01 || d < -0.01 {
		t.Fatalf("observed TTFT = %.4f, want %.4f (measured prefill used)", observedTTFT, wantObserved)
	}
	if observedTTFT >= fallbackTTFT {
		t.Fatalf("observed TTFT %.2f should be below fallback TTFT %.2f", observedTTFT, fallbackTTFT)
	}
}

func TestQuickCapacityCheckTTFTUsesObservedPrefillTPS(t *testing.T) {
	model := "ttft-observed-prefill-model"
	const prompt = 4000

	// Baseline provider: reports only the one-time registration prefill
	// benchmark (PrefillTPS). prefill term = 4000/400 = 10s.
	regBench := New(testLogger())
	pBench := makeSchedulerProvider(t, regBench, "bench", model, 100)
	pBench.mu.Lock()
	pBench.PrefillTPS = 400
	pBench.BackendCapacity.Slots[0].MaxConcurrency = 8
	pBench.mu.Unlock()
	_, _, _, benchTTFT, hasBench := regBench.QuickCapacityCheckWithTTFTForRequest(model, prompt, 128, RequestTraits{}, false)
	if !hasBench {
		t.Fatal("expected a TTFT estimate for the benchmark-only provider")
	}
	if benchTTFT <= 9*time.Second {
		t.Fatalf("benchmark TTFT = %v, want ~10s from the ×?? benchmark prefill", benchTTFT)
	}

	// Same provider also reporting a measured prefill EWMA 4× the benchmark.
	// prefill term = 4000/1600 = 2.5s, so the measured value must dominate and
	// the estimate must drop well below the benchmark-only path.
	regObs := New(testLogger())
	pObs := makeSchedulerProvider(t, regObs, "observed", model, 100)
	pObs.mu.Lock()
	pObs.PrefillTPS = 400
	pObs.BackendCapacity.Slots[0].MaxConcurrency = 8
	pObs.BackendCapacity.Slots[0].ObservedPrefillTPS = 1600
	pObs.mu.Unlock()
	_, _, _, obsTTFT, hasObs := regObs.QuickCapacityCheckWithTTFTForRequest(model, prompt, 128, RequestTraits{}, false)
	if !hasObs {
		t.Fatal("expected a TTFT estimate for the observed-prefill provider")
	}
	if obsTTFT >= benchTTFT {
		t.Fatalf("observed-prefill TTFT %v should be below benchmark-only TTFT %v", obsTTFT, benchTTFT)
	}
	if obsTTFT > 4*time.Second {
		t.Fatalf("observed-prefill TTFT = %v, want ~2.5s from the measured prefill rate", obsTTFT)
	}
}

func TestProjectedPerRequestDecodeTPS(t *testing.T) {
	k := effectiveTPSLoadFactor
	abs := func(x float64) float64 {
		if x < 0 {
			return -x
		}
		return x
	}
	approx := func(a, b float64) bool { return abs(a-b) < 0.01 }

	// Static fallback (no observed rate), idle provider: rate at batch 1 = static/(1+k).
	if got, want := projectedPerRequestDecodeTPS(routingSnapshot{decodeTPS: 25}), 25.0/(1+k); !approx(got, want) {
		t.Fatalf("static idle projected = %.2f, want %.2f", got, want)
	}
	// Observed rate measured at batch 2 is unwound to a solo rate, then reapplied
	// at batch 3 (the new request joins): solo = obs*(1+2k); proj = solo/(1+3k).
	snap := routingSnapshot{decodeTPS: 25, observedDecodeTPS: 20, backendRunning: 2}
	if got, want := projectedPerRequestDecodeTPS(snap), 20.0*(1+2*k)/(1+3*k); !approx(got, want) {
		t.Fatalf("observed projected = %.2f, want %.2f", got, want)
	}
	// No decode info -> 0 (treated as below any positive floor).
	if got := projectedPerRequestDecodeTPS(routingSnapshot{}); got != 0 {
		t.Fatalf("empty snapshot projected = %.2f, want 0", got)
	}
}

func TestReserveProviderDecodeFloorPrefersAboveFloor(t *testing.T) {
	reg := New(testLogger())
	model := "decode-floor-model"
	idle := makeSchedulerProvider(t, reg, "idle", model, 30) // batch 0 -> projected ~23.6 (>= 15)
	packed := makeSchedulerProvider(t, reg, "packed", model, 30)
	packed.mu.Lock()
	packed.BackendCapacity.Slots[0].NumRunning = 5        // batched (< maxConc, still a candidate)
	packed.BackendCapacity.Slots[0].ObservedDecodeTPS = 8 // measured low under load -> projected < 15
	packed.mu.Unlock()

	req := &PendingRequest{RequestID: "floor-1", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 128, MinDecodeTPS: 15}
	selected, decision := reg.ReserveProviderEx(model, req)
	if selected == nil {
		t.Fatalf("decode floor must not reject when a candidate exists: %+v", decision)
	}
	if selected.ID != idle.ID {
		t.Fatalf("decode floor selected %q, want the above-floor idle provider", selected.ID)
	}
}

func TestReserveProviderDecodeFloorNeverFailsClosed(t *testing.T) {
	reg := New(testLogger())
	model := "decode-floor-only-low"
	only := makeSchedulerProvider(t, reg, "only", model, 20)
	only.mu.Lock()
	only.BackendCapacity.Slots[0].NumRunning = 5
	only.BackendCapacity.Slots[0].ObservedDecodeTPS = 6 // projected well below the floor
	only.mu.Unlock()

	// Floor higher than any candidate can deliver: the gate is SOFT, so the
	// request must still be served on the best-available provider, not rejected.
	req := &PendingRequest{RequestID: "floor-2", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 128, MinDecodeTPS: 50}
	selected, decision := reg.ReserveProviderEx(model, req)
	if selected == nil {
		t.Fatalf("decode floor is SOFT and must still serve the only (below-floor) provider: %+v", decision)
	}
}

func TestReserveProviderExcludesSlowProviderWhenTTFTCeilingSet(t *testing.T) {
	reg := New(testLogger())
	model := "ttft-ceiling-model"

	// slow-but-cheap: cold state keeps its cost below the expensive provider,
	// but pushes its TTFT above the 10s target.
	slow := makeSchedulerProvider(t, reg, "slow", model, 100)
	slow.mu.Lock()
	slow.PrefillTPS = 1000
	slow.BackendCapacity.Slots[0].State = "idle_shutdown"
	slow.mu.Unlock()

	// fast-but-expensive: low decode TPS inflates cost, but TTFT stays tiny.
	fast := makeSchedulerProvider(t, reg, "fast", model, 1)
	fast.mu.Lock()
	fast.PrefillTPS = 1000
	fast.mu.Unlock()

	// Without a TTFT ceiling the router picks the slow (lower-cost) provider.
	reqNoCeiling := &PendingRequest{
		RequestID:             "req-no-ceiling",
		Model:                 model,
		EstimatedPromptTokens: 100,
		RequestedMaxTokens:    128,
	}
	selected, decision := reg.ReserveProviderEx(model, reqNoCeiling)
	if selected == nil {
		t.Fatalf("ReserveProviderEx returned nil: %+v", decision)
	}
	if selected.ID != slow.ID {
		t.Fatalf("without ceiling selected %q, want slow provider", selected.ID)
	}
	selected.RemovePending(reqNoCeiling.RequestID)
	reg.SetProviderIdle(selected.ID)

	// With the TTFT ceiling the router must exclude slow and pick fast.
	reqWithCeiling := &PendingRequest{
		RequestID:             "req-with-ceiling",
		Model:                 model,
		EstimatedPromptTokens: 100,
		RequestedMaxTokens:    128,
		MaxTTFTMs:             10_000, // 10s
	}
	selected, decision = reg.ReserveProviderEx(model, reqWithCeiling)
	if selected == nil {
		t.Fatalf("ReserveProviderEx returned nil: %+v", decision)
	}
	if selected.ID != fast.ID {
		t.Fatalf("with ceiling selected %q, want fast provider; decision=%+v", selected.ID, decision)
	}
	if decision.TTFTRejections != 1 {
		t.Fatalf("TTFTRejections = %d, want 1", decision.TTFTRejections)
	}
	if decision.BestTTFTMs <= 0 {
		t.Fatalf("BestTTFTMs = %f, want > 0", decision.BestTTFTMs)
	}
	if decision.TTFTMs > 10_000 {
		t.Fatalf("winning TTFTMs = %f, want <= 10000", decision.TTFTMs)
	}
}

func TestReserveProviderReturnsTTFTRejectionsWhenAllTooSlow(t *testing.T) {
	reg := New(testLogger())
	model := "ttft-all-slow-model"

	p := makeSchedulerProvider(t, reg, "slow", model, 100)
	p.mu.Lock()
	p.PrefillTPS = 1000
	p.BackendCapacity.Slots[0].State = "idle_shutdown"
	p.mu.Unlock()

	req := &PendingRequest{
		RequestID:             "req-all-slow",
		Model:                 model,
		EstimatedPromptTokens: 100,
		RequestedMaxTokens:    128,
		MaxTTFTMs:             10_000,
	}
	selected, decision := reg.ReserveProviderEx(model, req)
	if selected != nil {
		t.Fatalf("expected no provider, got %q", selected.ID)
	}
	if decision.TTFTRejections != 1 {
		t.Fatalf("TTFTRejections = %d, want 1", decision.TTFTRejections)
	}
	if decision.BestTTFTMs <= 10_000 {
		t.Fatalf("BestTTFTMs = %f, want > 10000", decision.BestTTFTMs)
	}
	if decision.CandidateCount != 0 {
		t.Fatalf("CandidateCount = %d, want 0", decision.CandidateCount)
	}
}

func TestReserveProviderHonorsAllowedProviderSerials(t *testing.T) {
	reg := New(testLogger())
	model := "targeted-model"
	fast := makeSchedulerProvider(t, reg, "fast-provider", model, 200)
	slow := makeSchedulerProvider(t, reg, "allowed-provider", model, 40)
	setSchedulerProviderSerial(fast, "FAST-SERIAL")
	setSchedulerProviderSerial(slow, "ALLOWED-SERIAL")

	req := &PendingRequest{
		RequestID:              "req-targeted",
		Model:                  model,
		RequestedMaxTokens:     128,
		AllowedProviderSerials: []string{"ALLOWED-SERIAL"},
	}
	selected, decision := reg.ReserveProviderEx(model, req)
	if selected == nil {
		t.Fatal("ReserveProviderEx returned nil")
	}
	if selected.ID != slow.ID {
		t.Fatalf("selected %q, want allowed provider %q", selected.ID, slow.ID)
	}
	if selected.ID == fast.ID {
		t.Fatal("selected provider outside allowlist")
	}
	if decision.CandidateCount != 1 {
		t.Fatalf("decision.CandidateCount=%d, want 1", decision.CandidateCount)
	}
}

func TestReserveProviderAllowedProviderSerialsWithExclusion(t *testing.T) {
	reg := New(testLogger())
	model := "targeted-excluded-model"
	p := makeSchedulerProvider(t, reg, "only-allowed", model, 100)
	setSchedulerProviderSerial(p, "ONLY-ALLOWED-SERIAL")

	req := &PendingRequest{
		RequestID:              "req-targeted-excluded",
		Model:                  model,
		RequestedMaxTokens:     128,
		AllowedProviderSerials: []string{"ONLY-ALLOWED-SERIAL"},
	}
	selected, decision := reg.ReserveProviderEx(model, req, p.ID)
	if selected != nil {
		t.Fatalf("selected %q, want nil because the only allowed provider is excluded", selected.ID)
	}
	if decision.CandidateCount != 0 {
		t.Fatalf("decision.CandidateCount=%d, want 0", decision.CandidateCount)
	}
}
