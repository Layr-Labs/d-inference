package registry

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func makeSchedulerProvider(t *testing.T, reg *Registry, id, model string, decodeTPS float64) *Provider {
	t.Helper()
	msg := testRegisterMessage()
	msg.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}
	msg.DecodeTPS = decodeTPS
	p := reg.Register(id, nil, msg)
	p.mu.Lock()
	p.TrustLevel = TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.SystemMetrics = protocol.SystemMetrics{
		MemoryPressure: 0.1,
		CPUUsage:       0.1,
		ThermalState:   "nominal",
	}
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{
			{
				Model:              model,
				State:              "running",
				NumRunning:         0,
				NumWaiting:         0,
				ActiveTokens:       0,
				MaxTokensPotential: 0,
			},
		},
	}
	p.mu.Unlock()
	return p
}

func setSchedulerProviderSerial(p *Provider, serial string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.AttestationResult = &attestation.VerificationResult{SerialNumber: serial}
}

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
		decision.BacklogMs + decision.ThisReqMs + decision.HealthMs
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

func TestDrainQueuedRequestsPopulatesDecision(t *testing.T) {
	reg := New(testLogger())
	model := "queue-decision-model"
	p := makeSchedulerProvider(t, reg, "p1", model, 90)
	p.mu.Lock()
	p.BackendCapacity = nil
	p.mu.Unlock()

	req := &QueuedRequest{
		RequestID:  "queued-decision",
		Model:      model,
		ResponseCh: make(chan *Provider, 1),
		Pending: &PendingRequest{
			RequestID:             "queued-decision",
			Model:                 model,
			RequestedMaxTokens:    256,
			EstimatedPromptTokens: 50,
		},
	}
	if err := reg.Queue().Enqueue(req); err != nil {
		t.Fatalf("enqueue: %v", err)
	}

	// SetProviderIdle triggers drainQueuedRequestsForModels which fills
	// req.Decision before signaling ResponseCh.
	reg.SetProviderIdle(p.ID)

	select {
	case assigned := <-req.ResponseCh:
		if assigned == nil {
			t.Fatal("expected provider, got nil")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for queue dispatch")
	}

	if req.Decision.ProviderID != p.ID {
		t.Fatalf("Decision.ProviderID=%q, want %q", req.Decision.ProviderID, p.ID)
	}
	if req.Decision.CostMs <= 0 {
		t.Fatalf("Decision.CostMs=%f, want > 0", req.Decision.CostMs)
	}
	if req.Decision.CandidateCount != 1 {
		t.Fatalf("Decision.CandidateCount=%d, want 1", req.Decision.CandidateCount)
	}
}

func TestDrainQueuedRequestsForProvider(t *testing.T) {
	reg := New(testLogger())
	model := "attest-drain-model"
	p := makeSchedulerProvider(t, reg, "p1", model, 90)

	// nil provider is a safe no-op (never panics).
	reg.DrainQueuedRequestsForProvider(nil)

	req := &QueuedRequest{
		RequestID:  "queued-attest",
		Model:      model,
		ResponseCh: make(chan *Provider, 1),
		Pending: &PendingRequest{
			RequestID:             "queued-attest",
			Model:                 model,
			RequestedMaxTokens:    256,
			EstimatedPromptTokens: 50,
		},
	}
	if err := reg.Queue().Enqueue(req); err != nil {
		t.Fatalf("enqueue: %v", err)
	}

	// Draining by provider (as on a CodeAttested flip) must dispatch the queued
	// request to that provider's model without waiting for a heartbeat.
	reg.DrainQueuedRequestsForProvider(p)

	select {
	case assigned := <-req.ResponseCh:
		if assigned == nil || assigned.ID != p.ID {
			t.Fatalf("expected dispatch to %q, got %+v", p.ID, assigned)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for provider-drain dispatch")
	}
}

func TestDrainQueuedRequestsSkipsUnassignableTargetedRequest(t *testing.T) {
	reg := New(testLogger())
	model := "queue-targeted-model"
	p := makeSchedulerProvider(t, reg, "available-provider", model, 90)
	setSchedulerProviderSerial(p, "AVAILABLE-SERIAL")

	targeted := &QueuedRequest{
		RequestID:  "queued-targeted",
		Model:      model,
		ResponseCh: make(chan *Provider, 1),
		Pending: &PendingRequest{
			RequestID:              "queued-targeted",
			Model:                  model,
			RequestedMaxTokens:     128,
			AllowedProviderSerials: []string{"MISSING-SERIAL"},
		},
	}
	untargeted := &QueuedRequest{
		RequestID:  "queued-untargeted",
		Model:      model,
		ResponseCh: make(chan *Provider, 1),
		Pending: &PendingRequest{
			RequestID:          "queued-untargeted",
			Model:              model,
			RequestedMaxTokens: 128,
		},
	}
	if err := reg.Queue().Enqueue(targeted); err != nil {
		t.Fatalf("enqueue targeted: %v", err)
	}
	if err := reg.Queue().Enqueue(untargeted); err != nil {
		t.Fatalf("enqueue untargeted: %v", err)
	}

	reg.SetProviderIdle(p.ID)

	select {
	case assigned := <-untargeted.ResponseCh:
		if assigned == nil {
			t.Fatal("untargeted request got nil provider")
		}
		if assigned.ID != p.ID {
			t.Fatalf("assigned %q, want %q", assigned.ID, p.ID)
		}
	case <-time.After(time.Second):
		t.Fatal("untargeted request was blocked behind unassignable targeted request")
	}

	select {
	case assigned := <-targeted.ResponseCh:
		t.Fatalf("targeted request should remain queued, got provider %#v", assigned)
	default:
	}
	if got := reg.Queue().QueueSize(model); got != 1 {
		t.Fatalf("queue size = %d, want 1 targeted request still queued", got)
	}
}

func TestReserveProviderExWhenNoneAvailable(t *testing.T) {
	reg := New(testLogger())
	model := "missing-model"

	req := &PendingRequest{
		RequestID:          "req-empty",
		Model:              model,
		RequestedMaxTokens: 256,
	}
	provider, decision := reg.ReserveProviderEx(model, req)
	if provider != nil {
		t.Fatalf("expected nil provider, got %q", provider.ID)
	}
	if decision.ProviderID != "" {
		t.Fatalf("decision.ProviderID=%q, want empty", decision.ProviderID)
	}
	if decision.Model != model {
		t.Fatalf("decision.Model=%q, want %q", decision.Model, model)
	}
	if decision.CandidateCount != 0 {
		t.Fatalf("decision.CandidateCount=%d, want 0", decision.CandidateCount)
	}
}

func TestReserveProviderBalancesAcrossHotSlots(t *testing.T) {
	reg := New(testLogger())
	model := "balanced-model"
	p1 := makeSchedulerProvider(t, reg, "p1", model, 120)
	p2 := makeSchedulerProvider(t, reg, "p2", model, 110)

	req1 := &PendingRequest{RequestID: "req-1", Model: model, RequestedMaxTokens: 256}
	first := reg.ReserveProvider(model, req1)
	if first == nil {
		t.Fatal("first reservation returned nil")
	}

	req2 := &PendingRequest{RequestID: "req-2", Model: model, RequestedMaxTokens: 256}
	second := reg.ReserveProvider(model, req2)
	if second == nil {
		t.Fatal("second reservation returned nil")
	}
	if first.ID == second.ID {
		t.Fatalf("expected second reservation to use a different provider, both went to %q", first.ID)
	}

	// Cleanup so later queue-drain logic isn't affected by sticky pending state.
	first.RemovePending(req1.RequestID)
	reg.SetProviderIdle(first.ID)
	second.RemovePending(req2.RequestID)
	reg.SetProviderIdle(second.ID)

	// Keep the variables live for readability in failure output.
	_ = p1
	_ = p2
}

func TestReserveProviderUsesColdSlotWhenHotBacklogIsHuge(t *testing.T) {
	reg := New(testLogger())
	model := "cold-start-model"
	hot := makeSchedulerProvider(t, reg, "hot", model, 40)
	cold := makeSchedulerProvider(t, reg, "cold", model, 40)

	hot.mu.Lock()
	hot.BackendCapacity.Slots[0].NumRunning = 1
	hot.BackendCapacity.Slots[0].NumWaiting = 2
	hot.BackendCapacity.Slots[0].MaxTokensPotential = 24_000
	hot.mu.Unlock()

	cold.mu.Lock()
	cold.BackendCapacity.Slots[0].State = "idle_shutdown"
	cold.mu.Unlock()

	req := &PendingRequest{
		RequestID:             "req-cold",
		Model:                 model,
		EstimatedPromptTokens: 2_000,
		RequestedMaxTokens:    512,
	}
	selected := reg.ReserveProvider(model, req)
	if selected == nil {
		t.Fatal("ReserveProvider returned nil")
	}
	if selected.ID != cold.ID {
		t.Fatalf("selected %q, want cold slot %q", selected.ID, cold.ID)
	}
}

func TestReserveProviderSkipsReloadingAndCrashedSlots(t *testing.T) {
	reg := New(testLogger())
	model := "slot-state-model"
	reloading := makeSchedulerProvider(t, reg, "reloading", model, 80)
	crashed := makeSchedulerProvider(t, reg, "crashed", model, 80)
	running := makeSchedulerProvider(t, reg, "running", model, 70)

	reloading.mu.Lock()
	reloading.BackendCapacity.Slots[0].State = "reloading"
	reloading.mu.Unlock()

	crashed.mu.Lock()
	crashed.BackendCapacity.Slots[0].State = "crashed"
	crashed.mu.Unlock()

	req := &PendingRequest{RequestID: "req-state", Model: model, RequestedMaxTokens: 256}
	selected := reg.ReserveProvider(model, req)
	if selected == nil {
		t.Fatal("ReserveProvider returned nil")
	}
	if selected.ID != running.ID {
		t.Fatalf("selected %q, want running provider %q", selected.ID, running.ID)
	}

	// If only crashed or reloading slots remain, routing should reject.
	selected.RemovePending(req.RequestID)
	reg.SetProviderIdle(selected.ID)
	running.mu.Lock()
	running.BackendCapacity.Slots[0].State = "crashed"
	running.mu.Unlock()

	req2 := &PendingRequest{RequestID: "req-none", Model: model, RequestedMaxTokens: 256}
	if got := reg.ReserveProvider(model, req2); got != nil {
		t.Fatalf("expected no reservation, got %q", got.ID)
	}
}

func TestSetProviderIdleKeepsUntrustedSticky(t *testing.T) {
	reg := New(testLogger())
	model := "sticky-untrusted-model"
	p := makeSchedulerProvider(t, reg, "p1", model, 80)
	p.AddPending(&PendingRequest{RequestID: "req-1", Model: model, RequestedMaxTokens: 128})

	reg.MarkUntrusted(p.ID)
	p.RemovePending("req-1")
	reg.SetProviderIdle(p.ID)

	p.mu.Lock()
	status := p.Status
	p.mu.Unlock()
	if status != StatusUntrusted {
		t.Fatalf("status = %q, want %q", status, StatusUntrusted)
	}
}

func TestDrainQueuedRequestsUsesAllAvailableCapacity(t *testing.T) {
	reg := New(testLogger())
	model := "queue-fill-model"
	p := makeSchedulerProvider(t, reg, "p1", model, 90)
	p.mu.Lock()
	p.BackendCapacity = nil // use default max concurrency (4) for deterministic headroom
	p.mu.Unlock()

	queued := make([]*QueuedRequest, 0, 3)
	for i := range 3 {
		req := &QueuedRequest{
			RequestID:  "queued-" + string(rune('a'+i)),
			Model:      model,
			ResponseCh: make(chan *Provider, 1),
			Pending: &PendingRequest{
				RequestID:          "queued-" + string(rune('a'+i)),
				Model:              model,
				RequestedMaxTokens: 128,
			},
		}
		if err := reg.Queue().Enqueue(req); err != nil {
			t.Fatalf("enqueue %d: %v", i, err)
		}
		queued = append(queued, req)
	}

	reg.SetProviderIdle(p.ID)

	for i, req := range queued {
		select {
		case assigned := <-req.ResponseCh:
			if assigned == nil {
				t.Fatalf("queued request %d received nil provider", i)
			}
			if assigned.ID != p.ID {
				t.Fatalf("queued request %d assigned %q, want %q", i, assigned.ID, p.ID)
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("timed out waiting for queued request %d", i)
		}
	}

	if got := p.PendingCount(); got != 3 {
		t.Fatalf("pending count = %d, want 3", got)
	}
}

func TestDrainQueuedRequestsRespectsPerSlotCapsAcrossModels(t *testing.T) {
	reg := New(testLogger())
	modelA := "queue-slot-full-a"
	modelB := "queue-slot-open-b"
	p := makeSchedulerProvider(t, reg, "multi-slot", modelA, 100)
	p.mu.Lock()
	p.Models = append(p.Models, protocol.ModelInfo{ID: modelB, ModelType: "chat", Quantization: "4bit"})
	p.BackendCapacity.Slots = []protocol.BackendSlotCapacity{
		{Model: modelA, State: "running", NumRunning: 0, NumWaiting: 0, MaxConcurrency: 1},
		{Model: modelB, State: "running", NumRunning: 0, NumWaiting: 0, MaxConcurrency: 1},
	}
	p.mu.Unlock()

	p.AddPending(&PendingRequest{RequestID: "existing-a", Model: modelA, RequestedMaxTokens: 128})
	queuedA := &QueuedRequest{
		RequestID:  "queued-a",
		Model:      modelA,
		ResponseCh: make(chan *Provider, 1),
		Pending:    &PendingRequest{RequestID: "queued-a", Model: modelA, RequestedMaxTokens: 128},
	}
	queuedB := &QueuedRequest{
		RequestID:  "queued-b",
		Model:      modelB,
		ResponseCh: make(chan *Provider, 1),
		Pending:    &PendingRequest{RequestID: "queued-b", Model: modelB, RequestedMaxTokens: 128},
	}
	if err := reg.Queue().Enqueue(queuedA); err != nil {
		t.Fatalf("enqueue A: %v", err)
	}
	if err := reg.Queue().Enqueue(queuedB); err != nil {
		t.Fatalf("enqueue B: %v", err)
	}

	reg.SetProviderIdle(p.ID)

	select {
	case assigned := <-queuedB.ResponseCh:
		if assigned == nil || assigned.ID != p.ID {
			t.Fatalf("queued B assigned %#v, want provider %q", assigned, p.ID)
		}
	default:
		t.Fatal("queued B should drain while model A is at its per-slot cap")
	}
	select {
	case assigned := <-queuedA.ResponseCh:
		t.Fatalf("queued A should remain queued at per-slot cap, got %#v", assigned)
	default:
	}
	if got := reg.Queue().QueueSize(modelA); got != 1 {
		t.Fatalf("model A queue size = %d, want 1", got)
	}
	if got := reg.Queue().QueueSize(modelB); got != 0 {
		t.Fatalf("model B queue size = %d, want 0", got)
	}
}

func TestSetProviderIdleDrainsOnlyFreedModelCapacity(t *testing.T) {
	reg := New(testLogger())
	modelA := "idle-freed-a"
	modelB := "idle-unchanged-b"
	p := makeSchedulerProvider(t, reg, "idle-multi", modelA, 100)
	p.mu.Lock()
	p.Models = append(p.Models, protocol.ModelInfo{ID: modelB, ModelType: "chat", Quantization: "4bit"})
	p.BackendCapacity.Slots = []protocol.BackendSlotCapacity{
		{Model: modelA, State: "running", NumRunning: 0, NumWaiting: 0, MaxConcurrency: 1},
		{Model: modelB, State: "running", NumRunning: 0, NumWaiting: 0, MaxConcurrency: 1},
	}
	p.mu.Unlock()

	p.AddPending(&PendingRequest{RequestID: "active-a", Model: modelA, RequestedMaxTokens: 128})
	p.AddPending(&PendingRequest{RequestID: "active-b", Model: modelB, RequestedMaxTokens: 128})
	queuedA := &QueuedRequest{
		RequestID:  "queued-a-after-free",
		Model:      modelA,
		ResponseCh: make(chan *Provider, 1),
		Pending:    &PendingRequest{RequestID: "queued-a-after-free", Model: modelA, RequestedMaxTokens: 128},
	}
	queuedB := &QueuedRequest{
		RequestID:  "queued-b-still-full",
		Model:      modelB,
		ResponseCh: make(chan *Provider, 1),
		Pending:    &PendingRequest{RequestID: "queued-b-still-full", Model: modelB, RequestedMaxTokens: 128},
	}
	if err := reg.Queue().Enqueue(queuedA); err != nil {
		t.Fatalf("enqueue A: %v", err)
	}
	if err := reg.Queue().Enqueue(queuedB); err != nil {
		t.Fatalf("enqueue B: %v", err)
	}

	p.RemovePending("active-a")
	reg.SetProviderIdle(p.ID)

	select {
	case assigned := <-queuedA.ResponseCh:
		if assigned == nil || assigned.ID != p.ID {
			t.Fatalf("queued A assigned %#v, want provider %q", assigned, p.ID)
		}
	default:
		t.Fatal("queued A should drain after model A capacity is freed")
	}
	select {
	case assigned := <-queuedB.ResponseCh:
		t.Fatalf("queued B should remain queued because model B capacity was not freed, got %#v", assigned)
	default:
	}
	if got := reg.Queue().QueueSize(modelA); got != 0 {
		t.Fatalf("model A queue size = %d, want 0", got)
	}
	if got := reg.Queue().QueueSize(modelB); got != 1 {
		t.Fatalf("model B queue size = %d, want 1", got)
	}
}

func TestReserveProviderUsesModelSpecificSlotState(t *testing.T) {
	reg := New(testLogger())
	modelA := "model-a"
	modelB := "model-b"
	msg := testRegisterMessage()
	msg.Models = []protocol.ModelInfo{
		{ID: modelA, ModelType: "chat", Quantization: "4bit"},
		{ID: modelB, ModelType: "chat", Quantization: "4bit"},
	}
	msg.DecodeTPS = 100
	p := reg.Register("multi", nil, msg)
	p.mu.Lock()
	p.TrustLevel = TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.SystemMetrics = protocol.SystemMetrics{
		MemoryPressure: 0.1,
		CPUUsage:       0.1,
		ThermalState:   "nominal",
	}
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{
			{Model: modelA, State: "running", NumRunning: 0, NumWaiting: 0},
			{Model: modelB, State: "crashed", NumRunning: 0, NumWaiting: 0},
		},
	}
	p.mu.Unlock()

	req := &PendingRequest{RequestID: "req-a", Model: modelA, RequestedMaxTokens: 128}
	selected := reg.ReserveProvider(modelA, req)
	if selected == nil {
		t.Fatal("ReserveProvider returned nil for healthy model slot")
	}
	if selected.ID != p.ID {
		t.Fatalf("selected %q, want %q", selected.ID, p.ID)
	}
}

func TestHeartbeatDrainsQueueAfterSlotRecovery(t *testing.T) {
	reg := New(testLogger())
	model := "recovery-model"
	p := makeSchedulerProvider(t, reg, "recover", model, 90)

	p.mu.Lock()
	p.BackendCapacity.Slots[0].State = "crashed"
	p.mu.Unlock()

	req := &QueuedRequest{
		RequestID:  "queued-recovery",
		Model:      model,
		ResponseCh: make(chan *Provider, 1),
		Pending: &PendingRequest{
			RequestID:          "queued-recovery",
			Model:              model,
			RequestedMaxTokens: 128,
		},
	}
	if err := reg.Queue().Enqueue(req); err != nil {
		t.Fatalf("enqueue: %v", err)
	}

	hb := &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "idle",
		Stats:  protocol.HeartbeatStats{},
		BackendCapacity: &protocol.BackendCapacity{
			TotalMemoryGB: 64,
			Slots: []protocol.BackendSlotCapacity{
				{Model: model, State: "running", NumRunning: 0, NumWaiting: 0},
			},
		},
		SystemMetrics: protocol.SystemMetrics{
			MemoryPressure: 0.1,
			CPUUsage:       0.1,
			ThermalState:   "nominal",
		},
	}
	reg.Heartbeat(p.ID, hb)

	select {
	case assigned := <-req.ResponseCh:
		if assigned == nil {
			t.Fatal("queued request received nil provider after recovery")
		}
		if assigned.ID != p.ID {
			t.Fatalf("assigned %q, want %q", assigned.ID, p.ID)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for recovered slot assignment")
	}
}

// ---------------------------------------------------------------------------
// Token-budget routing tests
// ---------------------------------------------------------------------------

func makeTokenBudgetProvider(t *testing.T, reg *Registry, id, model string, decodeTPS float64, budgetUsed, budgetMax int64, observedTPS float64) *Provider {
	t.Helper()
	p := makeSchedulerProvider(t, reg, id, model, decodeTPS)
	p.mu.Lock()
	if len(p.BackendCapacity.Slots) > 0 {
		p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = budgetUsed
		p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = budgetMax
		p.BackendCapacity.Slots[0].ObservedDecodeTPS = observedTPS
	}
	p.mu.Unlock()
	return p
}

func TestTokenBudgetAdmissionRejectsFullProvider(t *testing.T) {
	reg := New(testLogger())
	model := "budget-model"

	// Provider with budget nearly full: 30K used of 32K max.
	makeTokenBudgetProvider(t, reg, "full", model, 100, 30_000, 32_768, 80)
	// Provider with plenty of budget: 4K used of 32K max.
	makeTokenBudgetProvider(t, reg, "empty", model, 100, 4_000, 32_768, 80)

	req := &PendingRequest{
		RequestID:             "req-budget",
		Model:                 model,
		EstimatedPromptTokens: 500,
		RequestedMaxTokens:    4096,
	}
	selected := reg.ReserveProvider(model, req)
	if selected == nil {
		t.Fatal("expected a provider, got nil")
	}
	if selected.ID != "empty" {
		t.Fatalf("selected %q, want 'empty' (more budget headroom)", selected.ID)
	}
}

func TestTokenBudgetAdmissionRejectsWhenOverBudget(t *testing.T) {
	reg := New(testLogger())
	model := "overbudget-model"

	// Single provider with 31K used of 32K budget. Request needs 500+4096 = 4596 tokens.
	makeTokenBudgetProvider(t, reg, "full", model, 100, 31_000, 32_768, 80)

	req := &PendingRequest{
		RequestID:             "req-over",
		Model:                 model,
		EstimatedPromptTokens: 500,
		RequestedMaxTokens:    4096,
	}
	selected, decision := reg.ReserveProviderEx(model, req)
	if selected != nil {
		t.Fatalf("expected nil (over budget), got provider %q", selected.ID)
	}
	if decision.CapacityRejections != 1 {
		t.Fatalf("CapacityRejections=%d, want 1", decision.CapacityRejections)
	}
}

func TestTokenBudgetAdmissionCountsPendingPromptAndMaxTokens(t *testing.T) {
	reg := New(testLogger())
	model := "pending-budget-model"
	p := makeTokenBudgetProvider(t, reg, "budget", model, 100, 0, 5_000, 80)
	p.AddPending(&PendingRequest{
		RequestID:             "existing",
		Model:                 model,
		EstimatedPromptTokens: 3_000,
		RequestedMaxTokens:    1_000,
	})

	req := &PendingRequest{
		RequestID:             "new",
		Model:                 model,
		EstimatedPromptTokens: 1_000,
		RequestedMaxTokens:    256,
	}
	selected, decision := reg.ReserveProviderEx(model, req)
	if selected != nil {
		t.Fatalf("selected %q, want nil because pending prompt+max exhausts budget", selected.ID)
	}
	if decision.CapacityRejections != 1 {
		t.Fatalf("CapacityRejections=%d, want 1", decision.CapacityRejections)
	}
}

func TestQuickCapacityCheckCountsPendingPromptAndMaxTokens(t *testing.T) {
	reg := New(testLogger())
	model := "quick-pending-budget-model"
	p := makeTokenBudgetProvider(t, reg, "budget", model, 100, 0, 5_000, 80)
	p.AddPending(&PendingRequest{
		RequestID:             "existing",
		Model:                 model,
		EstimatedPromptTokens: 3_000,
		RequestedMaxTokens:    1_000,
	})

	candidates, rejections, _ := reg.QuickCapacityCheck(model, 1_000, 256, RequestTraits{})
	if candidates != 0 || rejections != 1 {
		t.Fatalf("QuickCapacityCheck candidates=%d rejections=%d, want 0/1", candidates, rejections)
	}
}

func TestTokenBudgetDoesNotDoubleCountBackendQueuedBudget(t *testing.T) {
	reg := New(testLogger())
	model := "queued-overlap-budget-model"
	p := makeTokenBudgetProvider(t, reg, "budget", model, 100, 1_000, 5_000, 80)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].MaxTokensPotential = 1_000
	p.BackendCapacity.Slots[0].QueuedTokenBudget = 3_000
	p.mu.Unlock()
	p.AddPending(&PendingRequest{
		RequestID:             "existing",
		Model:                 model,
		EstimatedPromptTokens: 3_000,
		RequestedMaxTokens:    1_000,
	})

	req := &PendingRequest{
		RequestID:             "new",
		Model:                 model,
		EstimatedPromptTokens: 100,
		RequestedMaxTokens:    128,
	}
	selected, decision := reg.ReserveProviderEx(model, req)
	if selected == nil {
		t.Fatalf("selected nil, want provider; decision=%+v", decision)
	}
	if selected.ID != p.ID {
		t.Fatalf("selected %q, want %q", selected.ID, p.ID)
	}
}

func TestObservedTPSPreferredOverBenchmark(t *testing.T) {
	reg := New(testLogger())
	model := "tps-model"

	// Provider A: high benchmark TPS but low observed TPS (under load).
	makeTokenBudgetProvider(t, reg, "bench-fast", model, 200, 0, 32_768, 30)
	// Provider B: lower benchmark TPS but higher observed TPS (lightly loaded).
	makeTokenBudgetProvider(t, reg, "bench-slow", model, 50, 0, 32_768, 70)

	req := &PendingRequest{
		RequestID:             "req-tps",
		Model:                 model,
		EstimatedPromptTokens: 100,
		RequestedMaxTokens:    2048,
	}
	selected, decision := reg.ReserveProviderEx(model, req)
	if selected == nil {
		t.Fatal("expected a provider, got nil")
	}
	// Provider B has higher observed TPS (70 vs 30), so its thisReqMs is lower.
	if selected.ID != "bench-slow" {
		t.Fatalf("selected %q, want 'bench-slow' (higher observed TPS)", selected.ID)
	}
	if decision.EffectiveTPS <= 0 {
		t.Fatalf("EffectiveTPS=%f, want > 0", decision.EffectiveTPS)
	}
}

func TestTokenBudgetBacklogCost(t *testing.T) {
	reg := New(testLogger())
	model := "backlog-model"

	// Provider A: large backlog (20K tokens used).
	makeTokenBudgetProvider(t, reg, "heavy", model, 100, 20_000, 32_768, 80)
	// Provider B: light backlog (2K tokens used).
	makeTokenBudgetProvider(t, reg, "light", model, 100, 2_000, 32_768, 80)

	req := &PendingRequest{
		RequestID:             "req-backlog",
		Model:                 model,
		EstimatedPromptTokens: 100,
		RequestedMaxTokens:    256,
	}
	selected, decision := reg.ReserveProviderEx(model, req)
	if selected == nil {
		t.Fatal("expected a provider, got nil")
	}
	if selected.ID != "light" {
		t.Fatalf("selected %q, want 'light' (lower backlog)", selected.ID)
	}
	if decision.BacklogMs <= 0 {
		t.Fatalf("BacklogMs=%f, want > 0 (should reflect token backlog)", decision.BacklogMs)
	}
}

func TestMaxConcurrencyRaisedWithTokenBudget(t *testing.T) {
	reg := New(testLogger())
	model := "concurrency-model"

	p := makeTokenBudgetProvider(t, reg, "budget-provider", model, 100, 0, 32_768, 80)
	if got := p.MaxConcurrency(); got != 24 {
		t.Fatalf("MaxConcurrency()=%d, want 24 (token budget reported)", got)
	}
}

func TestMaxConcurrencyFallsBackWithoutTokenBudget(t *testing.T) {
	reg := New(testLogger())
	model := "legacy-model"

	// Provider without token budget fields (legacy behavior).
	p := makeSchedulerProvider(t, reg, "legacy", model, 100)
	p.mu.Lock()
	p.BackendCapacity.TotalMemoryGB = 48
	p.mu.Unlock()

	if got := p.MaxConcurrency(); got != 4 {
		t.Fatalf("MaxConcurrency()=%d, want 4 (48GB legacy tier)", got)
	}
}

func TestPerSlotMaxConcurrencyLimitsRoutingForModel(t *testing.T) {
	reg := New(testLogger())
	model := "slot-capped-model"
	p := makeSchedulerProvider(t, reg, "capped", model, 100)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].MaxConcurrency = 1
	p.mu.Unlock()

	first := &PendingRequest{RequestID: "req-first", Model: model, RequestedMaxTokens: 128}
	if selected := reg.ReserveProvider(model, first); selected == nil {
		t.Fatal("first request should route")
	}

	second := &PendingRequest{RequestID: "req-second", Model: model, RequestedMaxTokens: 128}
	selected, decision := reg.ReserveProviderEx(model, second)
	if selected != nil {
		t.Fatalf("second request selected %q, want nil at per-slot cap", selected.ID)
	}
	if decision.CandidateCount != 0 || decision.CapacityRejections != 1 {
		t.Fatalf("decision=%+v, want one capacity rejection at per-slot cap", decision)
	}

	candidates, rejections, _ := reg.QuickCapacityCheck(model, 100, 128, RequestTraits{})
	if candidates != 0 || rejections != 1 {
		t.Fatalf("QuickCapacityCheck candidates=%d rejections=%d, want 0/1", candidates, rejections)
	}
	if found := reg.FindProvider(model); found != nil {
		t.Fatalf("FindProvider selected %q, want nil at per-slot cap", found.ID)
	}
	if score := ScoreProvider(p, model); score != 0 {
		t.Fatalf("ScoreProvider=%f, want 0 at per-slot cap", score)
	}
}

func TestPerSlotMaxConcurrencyZeroFallsBack(t *testing.T) {
	reg := New(testLogger())
	model := "slot-zero-model"
	p := makeSchedulerProvider(t, reg, "fallback", model, 100)
	p.mu.Lock()
	p.BackendCapacity.TotalMemoryGB = 64
	p.BackendCapacity.Slots[0].MaxConcurrency = 0
	p.mu.Unlock()

	if got := p.MaxConcurrencyForModel(model); got != 6 {
		t.Fatalf("MaxConcurrencyForModel()=%d, want fallback 6", got)
	}
	for i := range 4 {
		p.AddPending(&PendingRequest{RequestID: fmt.Sprintf("existing-%d", i), Model: model})
	}
	candidates, rejections, _ := reg.QuickCapacityCheck(model, 100, 128, RequestTraits{})
	if candidates != 1 || rejections != 0 {
		t.Fatalf("QuickCapacityCheck candidates=%d rejections=%d, want 1/0", candidates, rejections)
	}
	if found := reg.FindProvider(model); found == nil {
		t.Fatal("FindProvider should use fallback cap when max_concurrency is zero")
	}
}

// TestQuickCapacityCheckReportsModelTooLarge is the preflight half of the
// model_too_large fix: a cold model that can never fit must be reported as
// modelTooLarge, NOT capacityRejections — otherwise the consumer preflight 429s
// it and the client retries a model that will never fit. Regression for the
// Codex review finding on the QuickCapacityCheck preflight.
func TestQuickCapacityCheckReportsModelTooLarge(t *testing.T) {
	reg := New(testLogger())
	model := "preflight-too-large"
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 128}}) // needs 128*2=256GB
	p := makeSchedulerProvider(t, reg, "small-box", model, 80)
	p.mu.Lock()
	p.BackendCapacity.TotalMemoryGB = 64
	p.BackendCapacity.Slots[0].State = "idle_shutdown" // cold: model not resident
	p.mu.Unlock()

	candidates, rejections, tooLarge := reg.QuickCapacityCheck(model, 100, 128, RequestTraits{})
	if candidates != 0 || rejections != 0 || tooLarge != 1 {
		t.Fatalf("QuickCapacityCheck = (cand=%d, rej=%d, tooLarge=%d), want 0/0/1", candidates, rejections, tooLarge)
	}
}

// TestModelFitPrefersCatalogMinRAM is the core fix: the fit gate must use the
// catalog's authoritative min_ram_gb, NOT a synthetic multiple of the weight.
// A 28 GB-weight model (gemma-like) with min_ram_gb=36 must be ADMITTED on a
// 64 GB box (a multiplier of 2.x would have wrongly rejected the whole 64 GB
// tier), and REJECTED on a 24 GB box (below the published minimum).
func TestModelFitPrefersCatalogMinRAM(t *testing.T) {
	model := "gemma-like"
	// Qualifies on 64 GB (min_ram_gb=36 ≤ 64).
	reg := New(testLogger())
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 28, MinRAMGB: 36}})
	p := makeSchedulerProvider(t, reg, "box64", model, 80)
	p.mu.Lock()
	p.BackendCapacity.TotalMemoryGB = 64
	p.BackendCapacity.Slots[0].State = "idle_shutdown" // cold: gate applies
	p.mu.Unlock()
	if _, _, tooLarge := reg.QuickCapacityCheck(model, 100, 128, RequestTraits{}); tooLarge != 0 {
		t.Fatalf("min_ram_gb=36 on 64GB box must be admitted, got modelTooLarge=%d", tooLarge)
	}

	// Rejected on 24 GB (below min_ram_gb=36).
	reg2 := New(testLogger())
	reg2.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 28, MinRAMGB: 36}})
	small := makeSchedulerProvider(t, reg2, "box24", model, 80)
	small.mu.Lock()
	small.BackendCapacity.TotalMemoryGB = 24
	small.BackendCapacity.Slots[0].State = "idle_shutdown"
	small.mu.Unlock()
	if _, _, tooLarge := reg2.QuickCapacityCheck(model, 100, 128, RequestTraits{}); tooLarge != 1 {
		t.Fatalf("min_ram_gb=36 on 24GB box must be model_too_large, got %d", tooLarge)
	}
}

// TestModelFitGptOssOn24GB is the operator-facing case: gpt-oss-20b
// (min_ram_gb=24) must be ADMITTED on a 24 GB box — the catalog says it
// qualifies, and a weight×multiplier gate (12.1×2.x > 24) would wrongly reject
// it and starve every 24 GB node of traffic.
func TestModelFitGptOssOn24GB(t *testing.T) {
	reg := New(testLogger())
	model := "gpt-oss-20b"
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 12.1, MinRAMGB: 24}})
	p := makeSchedulerProvider(t, reg, "box24", model, 80)
	p.mu.Lock()
	p.BackendCapacity.TotalMemoryGB = 24
	p.BackendCapacity.Slots[0].State = "idle_shutdown"
	p.mu.Unlock()
	if _, _, tooLarge := reg.QuickCapacityCheck(model, 100, 128, RequestTraits{}); tooLarge != 0 {
		t.Fatalf("gpt-oss-20b (min_ram_gb=24) on a 24GB box must be admitted, got modelTooLarge=%d", tooLarge)
	}
}

func TestPerSlotMaxConcurrencyUsesBackendReportedLoad(t *testing.T) {
	reg := New(testLogger())
	model := "backend-loaded-model"
	p := makeSchedulerProvider(t, reg, "backend-loaded", model, 100)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].MaxConcurrency = 1
	p.BackendCapacity.Slots[0].NumRunning = 1
	p.mu.Unlock()

	selected, decision := reg.ReserveProviderEx(model, &PendingRequest{
		RequestID:          "req-over-backend-cap",
		Model:              model,
		RequestedMaxTokens: 128,
	})
	if selected != nil {
		t.Fatalf("selected %q, want nil at backend-reported slot cap", selected.ID)
	}
	if decision.CandidateCount != 0 || decision.CapacityRejections != 1 {
		t.Fatalf("decision=%+v, want one capacity rejection from backend slot load", decision)
	}

	candidates, rejections, _ := reg.QuickCapacityCheck(model, 100, 128, RequestTraits{})
	if candidates != 0 || rejections != 1 {
		t.Fatalf("QuickCapacityCheck candidates=%d rejections=%d, want 0/1", candidates, rejections)
	}
}

func TestManyPerSlotCapsRespectProviderWideAggregateCap(t *testing.T) {
	reg := New(testLogger())
	models := make([]string, 0, 8)
	for i := range 8 {
		models = append(models, fmt.Sprintf("aggregate-cap-model-%d", i))
	}
	p := makeSchedulerProvider(t, reg, "aggregate-cap", models[0], 100)
	p.mu.Lock()
	p.Models = p.Models[:0]
	p.BackendCapacity.Slots = p.BackendCapacity.Slots[:0]
	for _, model := range models {
		p.Models = append(p.Models, protocol.ModelInfo{ID: model, ModelType: "chat", Quantization: "4bit"})
		p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
			Model:                model,
			State:                "running",
			MaxConcurrency:       8,
			ActiveTokenBudgetMax: 32_768,
		})
	}
	p.mu.Unlock()

	for i := range 24 {
		p.AddPending(&PendingRequest{
			RequestID:          fmt.Sprintf("existing-%d", i),
			Model:              models[i%len(models)],
			RequestedMaxTokens: 128,
		})
	}

	selected, decision := reg.ReserveProviderEx(models[0], &PendingRequest{
		RequestID:             "req-over-aggregate-cap",
		Model:                 models[0],
		EstimatedPromptTokens: 100,
		RequestedMaxTokens:    128,
	})
	if selected != nil {
		t.Fatalf("selected %q, want nil at provider-wide aggregate cap", selected.ID)
	}
	if decision.CandidateCount != 0 || decision.CapacityRejections != 1 {
		t.Fatalf("decision=%+v, want one capacity rejection at aggregate cap", decision)
	}
	candidates, rejections, _ := reg.QuickCapacityCheck(models[0], 100, 128, RequestTraits{})
	if candidates != 0 || rejections != 1 {
		t.Fatalf("QuickCapacityCheck candidates=%d rejections=%d, want 0/1", candidates, rejections)
	}
}

func TestModelCapacitySnapshotRespectsPerSlotMaxConcurrency(t *testing.T) {
	reg := New(testLogger())
	modelA := "snapshot-full-model"
	modelB := "snapshot-open-model"
	p := makeSchedulerProvider(t, reg, "snapshot-provider", modelA, 100)
	p.mu.Lock()
	p.Models = append(p.Models, protocol.ModelInfo{ID: modelB, ModelType: "chat", Quantization: "4bit"})
	p.BackendCapacity.Slots = []protocol.BackendSlotCapacity{
		{Model: modelA, State: "running", NumRunning: 1, MaxConcurrency: 1},
		{Model: modelB, State: "running", NumRunning: 0, MaxConcurrency: 2},
	}
	p.mu.Unlock()

	snapshots := reg.ModelCapacitySnapshot()
	byModel := make(map[string]ModelCapacity, len(snapshots))
	for _, snap := range snapshots {
		byModel[snap.ModelID] = snap
	}

	full, ok := byModel[modelA]
	if !ok {
		t.Fatalf("missing snapshot for %s", modelA)
	}
	if full.Ready || full.CanAccept || full.RoutableProviders != 0 {
		t.Fatalf("full model snapshot=%+v, want not ready/routable", full)
	}
	if full.ActiveRequests != 1 {
		t.Fatalf("full model active_requests=%d, want 1", full.ActiveRequests)
	}

	open, ok := byModel[modelB]
	if !ok {
		t.Fatalf("missing snapshot for %s", modelB)
	}
	if !open.Ready || !open.CanAccept || open.RoutableProviders != 1 {
		t.Fatalf("open model snapshot=%+v, want ready with one routable provider", open)
	}
}

func TestLegacyProviderFallsBackToOldRouting(t *testing.T) {
	reg := New(testLogger())
	model := "legacy-routing-model"

	// Two legacy providers (no token budget fields) — should use old cost function.
	p1 := makeSchedulerProvider(t, reg, "fast", model, 120)
	p2 := makeSchedulerProvider(t, reg, "slow", model, 40)
	_ = p1
	_ = p2

	req := &PendingRequest{
		RequestID:             "req-legacy",
		Model:                 model,
		EstimatedPromptTokens: 100,
		RequestedMaxTokens:    256,
	}
	selected := reg.ReserveProvider(model, req)
	if selected == nil {
		t.Fatal("expected a provider, got nil")
	}
	// Faster decode TPS should win when both idle with no budget reporting.
	if selected.ID != "fast" {
		t.Fatalf("selected %q, want 'fast' (higher decode TPS in legacy mode)", selected.ID)
	}
}

func TestResolveEffectiveTPSFallback(t *testing.T) {
	// When observedDecodeTPS is 0, should fall back to formula-based TPS.
	snap := routingSnapshot{
		decodeTPS:         100,
		backendRunning:    2,
		observedDecodeTPS: 0,
	}
	got := resolveEffectiveTPS(snap)
	want := effectiveDecodeTPS(100, 2)
	if got != want {
		t.Fatalf("resolveEffectiveTPS()=%f, want %f (formula fallback)", got, want)
	}

	// When observedDecodeTPS is set, should use it directly.
	snap.observedDecodeTPS = 55.5
	got = resolveEffectiveTPS(snap)
	if got != 55.5 {
		t.Fatalf("resolveEffectiveTPS()=%f, want 55.5 (observed)", got)
	}
}

func TestFreeMemoryAdmitsTokenBudget(t *testing.T) {
	// With token budget, should use budget-based admission.
	snap := routingSnapshot{
		activeTokenBudgetUsed: 28_000,
		activeTokenBudgetMax:  32_768,
		modelSizeGB:           8,
		totalMemoryGB:         64,
	}
	// Request for 500 + 4096 = 4596 tokens. 28000 + 4596 = 32596 <= 32768. Fits.
	if !freeMemoryAdmits(snap, 500, 4096) {
		t.Fatal("should admit: 28000 + 4596 = 32596 <= 32768")
	}
	// Request for 500 + 4500 = 5000 tokens. 28000 + 5000 = 33000 > 32768. Rejected.
	if freeMemoryAdmits(snap, 500, 4500) {
		t.Fatal("should reject: 28000 + 5000 = 33000 > 32768")
	}
}

func TestFreeMemoryAdmitsIncludesQueuedBudget(t *testing.T) {
	snap := routingSnapshot{
		activeTokenBudgetUsed: 20_000,
		activeTokenBudgetMax:  32_768,
		queuedTokenBudget:     10_000,
		modelSizeGB:           8,
		totalMemoryGB:         64,
	}
	// active(20K) + queued(10K) + request(500+4096=4596) = 34596 > 32768. Rejected.
	if freeMemoryAdmits(snap, 500, 4096) {
		t.Fatal("should reject: active + queued + request exceeds budget")
	}
	// Without queued budget: active(20K) + request(4596) = 24596 <= 32768. Fits.
	snap.queuedTokenBudget = 0
	if !freeMemoryAdmits(snap, 500, 4096) {
		t.Fatal("should admit when queued budget is zero")
	}
}

func TestFreeMemoryAdmitsFallsBackWithoutBudget(t *testing.T) {
	// Without token budget (max=0), should fall back to memory-based check.
	snap := routingSnapshot{
		activeTokenBudgetUsed: 0,
		activeTokenBudgetMax:  0,
		modelSizeGB:           8,
		totalMemoryGB:         64,
		gpuMemoryActiveGB:     10,
		modelLoaded:           true,
	}
	// Model already loaded, so only KV matters. Lots of free memory.
	if !freeMemoryAdmits(snap, 100, 256) {
		t.Fatal("should admit with plenty of free memory in legacy mode")
	}
}

func TestSlotHeadroomWithExhaustedTokenBudgetRejectsCapacity(t *testing.T) {
	reg := New(testLogger())
	model := "budget-headroom-model"
	p := makeTokenBudgetProvider(t, reg, "budget-headroom", model, 100, 32_000, 32_768, 80)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].MaxConcurrency = 8
	p.mu.Unlock()

	selected, decision := reg.ReserveProviderEx(model, &PendingRequest{
		RequestID:             "req-budget-reject",
		Model:                 model,
		EstimatedPromptTokens: 256,
		RequestedMaxTokens:    1024,
	})
	if selected != nil {
		t.Fatalf("selected %q, want nil with exhausted token budget", selected.ID)
	}
	if decision.CandidateCount != 0 || decision.CapacityRejections != 1 {
		t.Fatalf("decision=%+v, want one capacity rejection from token budget", decision)
	}
	candidates, rejections, _ := reg.QuickCapacityCheck(model, 256, 1024, RequestTraits{})
	if candidates != 0 || rejections != 1 {
		t.Fatalf("QuickCapacityCheck candidates=%d rejections=%d, want 0/1", candidates, rejections)
	}
}

// QuickCapacityCheck must mirror the routing path's per-provider gates: for a
// tools request it must exclude (a) a pair in the shape-keyed inference-error
// cooldown for the tools shape and (b) a trait-ineligible provider (below the
// tools floor or render-broken). Without this the preflight reports phantom
// capacity that routing then refuses, queueing the request to a misleading 429.
func TestQuickCapacityCheckExcludesShapeCooledAndTraitIneligible(t *testing.T) {
	reg := New(testLogger())
	model := "preflight-tools-model"
	toolTraits := RequestTraits{HasTools: true}

	// All providers at/above the tools floor unless stated; render verdict nil.
	cooled := makeSchedulerProvider(t, reg, "cooled", model, 100)
	belowFloor := makeSchedulerProvider(t, reg, "below-floor", model, 100)
	renderBroken := makeSchedulerProvider(t, reg, "render-broken", model, 100)
	healthy := makeSchedulerProvider(t, reg, "healthy", model, 100)
	setProviderVersion(cooled, "0.6.5")
	setProviderVersion(belowFloor, "0.6.2") // below the 0.6.3 tools floor
	setProviderVersion(renderBroken, "0.6.5")
	setProviderVersion(healthy, "0.6.5")
	renderBroken.mu.Lock()
	renderBroken.Models[0].TemplateRenderOK = boolPtr(false)
	renderBroken.mu.Unlock()

	// Quarantine the "cooled" provider for the TOOLS shape only.
	reg.RecordInferenceError(cooled.ID, model, 500, "tools")
	if !reg.RecordInferenceError(cooled.ID, model, 500, "tools") {
		t.Fatal("two tools strikes should trip the tools cooldown")
	}

	// For a TOOLS request, only the healthy provider is a candidate.
	candidates, rejections, tooLarge := reg.QuickCapacityCheck(model, 100, 128, toolTraits)
	if candidates != 1 || rejections != 0 || tooLarge != 0 {
		t.Fatalf("tools QuickCapacityCheck = (cand=%d rej=%d tooLarge=%d), want 1/0/0 (only healthy)", candidates, rejections, tooLarge)
	}

	// For a BASE request, the tools cooldown and tools floor do not apply, so the
	// cooled, below-floor, and healthy providers all qualify — but render-broken
	// is still excluded for every shape.
	baseCandidates, baseRej, _ := reg.QuickCapacityCheck(model, 100, 128, RequestTraits{})
	if baseCandidates != 3 || baseRej != 0 {
		t.Fatalf("base QuickCapacityCheck = (cand=%d rej=%d), want 3/0 (render-broken excluded; tools gates inactive)", baseCandidates, baseRej)
	}
}

// Render-broken must fence a NON-tool request too: a crashing chat template
// breaks every request shape, so a base request must skip the render-broken
// provider and only the healthy one remains a candidate.
func TestQuickCapacityCheckExcludesRenderBrokenForBaseRequest(t *testing.T) {
	reg := New(testLogger())
	model := "preflight-render-broken-base"
	broken := makeSchedulerProvider(t, reg, "render-broken", model, 100)
	healthy := makeSchedulerProvider(t, reg, "healthy", model, 100)
	broken.mu.Lock()
	broken.Models[0].TemplateRenderOK = boolPtr(false)
	broken.mu.Unlock()
	healthy.mu.Lock()
	healthy.Models[0].TemplateRenderOK = boolPtr(true)
	healthy.mu.Unlock()

	candidates, rejections, _ := reg.QuickCapacityCheck(model, 100, 128, RequestTraits{})
	if candidates != 1 || rejections != 0 {
		t.Fatalf("base QuickCapacityCheck = (cand=%d rej=%d), want 1/0 (render-broken fenced for base too)", candidates, rejections)
	}
}

// Scheduler integration: a render-broken provider must be excluded from a
// NON-tool ReserveProviderEx too — the routing path, not just the preflight,
// fences every shape.
func TestReserveProviderExSkipsRenderBrokenForBaseRequest(t *testing.T) {
	reg := New(testLogger())
	model := "render-broken-base-route"
	broken := makeSchedulerProvider(t, reg, "render-broken", model, 200)
	healthy := makeSchedulerProvider(t, reg, "healthy", model, 50)
	broken.mu.Lock()
	broken.Models[0].TemplateRenderOK = boolPtr(false)
	broken.mu.Unlock()
	healthy.mu.Lock()
	healthy.Models[0].TemplateRenderOK = boolPtr(true)
	healthy.mu.Unlock()

	plain := &PendingRequest{RequestID: "r-plain", Model: model, RequestedMaxTokens: 128}
	selected, decision := reg.ReserveProviderEx(model, plain)
	if selected == nil || selected.ID != healthy.ID {
		t.Fatalf("plain request selected %v, want %q (render-broken excluded for all shapes)", selected, healthy.ID)
	}
	if decision.CandidateCount != 1 {
		t.Fatalf("CandidateCount=%d, want 1 (render-broken fenced for base too)", decision.CandidateCount)
	}
}

// QuickCapacityCheck must honor allowedSerials: a capable-but-not-allowed
// provider does not satisfy the preflight for a constrained request.
func TestQuickCapacityCheckHonorsAllowedSerials(t *testing.T) {
	reg := New(testLogger())
	model := "preflight-allowed-serial"
	allowed := makeSchedulerProvider(t, reg, "allowed", model, 100)
	other := makeSchedulerProvider(t, reg, "other", model, 100)
	setSchedulerProviderSerial(allowed, "ALLOWED-SERIAL")
	setSchedulerProviderSerial(other, "OTHER-SERIAL")

	// Unconstrained: both qualify.
	if c, _, _ := reg.QuickCapacityCheck(model, 100, 128, RequestTraits{}); c != 2 {
		t.Fatalf("unconstrained candidates=%d, want 2", c)
	}
	// Constrained to ALLOWED-SERIAL: only that provider qualifies.
	if c, _, _ := reg.QuickCapacityCheck(model, 100, 128, RequestTraits{}, "ALLOWED-SERIAL"); c != 1 {
		t.Fatalf("constrained candidates=%d, want 1 (only the allowed serial)", c)
	}
	// Constrained to a serial nobody has: zero candidates.
	if c, _, _ := reg.QuickCapacityCheck(model, 100, 128, RequestTraits{}, "MISSING-SERIAL"); c != 0 {
		t.Fatalf("missing-serial candidates=%d, want 0", c)
	}
}

// HasToolCapableProviderForModel and HasVisionProviderForModel must honor
// allowedSerials: a capable provider whose serial is not in the allowed set
// does NOT satisfy the check, so a constrained request is not falsely reported
// as serviceable by an unrelated public provider.
func TestCapabilityChecksHonorAllowedSerials(t *testing.T) {
	reg := New(testLogger())
	model := "capability-allowed-serial"

	// One tool-capable + vision-capable provider, serial NOT in the allowlist.
	capable := makeSchedulerProvider(t, reg, "capable-not-allowed", model, 100)
	setProviderVersion(capable, "0.6.5")
	setSchedulerProviderSerial(capable, "CAPABLE-SERIAL")
	capable.mu.Lock()
	capable.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit", IsVision: true}}
	capable.mu.Unlock()

	// Unconstrained: both capabilities satisfied.
	if !reg.HasToolCapableProviderForModel(model) {
		t.Fatal("unconstrained: expected a tool-capable provider")
	}
	if !reg.HasVisionProviderForModel(model) {
		t.Fatal("unconstrained: expected a vision-capable provider")
	}

	// Constrained to a serial the capable provider does NOT have: neither check
	// may be satisfied by it.
	if reg.HasToolCapableProviderForModel(model, "ALLOWED-ONLY") {
		t.Fatal("a tool-capable but not-allowed provider must not satisfy a constrained tools check")
	}
	if reg.HasVisionProviderForModel(model, "ALLOWED-ONLY") {
		t.Fatal("a vision-capable but not-allowed provider must not satisfy a constrained vision check")
	}

	// Constrained to the capable provider's own serial: both checks pass again.
	if !reg.HasToolCapableProviderForModel(model, "CAPABLE-SERIAL") {
		t.Fatal("constrained to its own serial, the capable provider must satisfy the tools check")
	}
	if !reg.HasVisionProviderForModel(model, "CAPABLE-SERIAL") {
		t.Fatal("constrained to its own serial, the capable provider must satisfy the vision check")
	}
}

func TestQuickCapacityCheckForRequestRequiresVision(t *testing.T) {
	reg := New(testLogger())
	model := "vision-preflight-model"
	textOnly := makeSchedulerProvider(t, reg, "text-only", model, 100)
	textOnly.mu.Lock()
	textOnly.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit", IsVision: false}}
	textOnly.mu.Unlock()

	if candidates, rejections, tooLarge := reg.QuickCapacityCheckForRequest(model, 100, 128, RequestTraits{}, true); candidates != 0 || rejections != 0 || tooLarge != 0 {
		t.Fatalf("vision preflight with text-only provider = (%d,%d,%d), want 0/0/0", candidates, rejections, tooLarge)
	}

	vision := makeSchedulerProvider(t, reg, "vision", model, 100)
	vision.mu.Lock()
	vision.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit", IsVision: true}}
	vision.mu.Unlock()

	if candidates, _, _ := reg.QuickCapacityCheckForRequest(model, 100, 128, RequestTraits{}, true); candidates != 1 {
		t.Fatalf("vision preflight candidates=%d, want 1", candidates)
	}
}

func TestQuickCapacityCheckExcludesCriticalThermal(t *testing.T) {
	reg := New(testLogger())
	model := "critical-thermal-preflight"
	p := makeSchedulerProvider(t, reg, "hot", model, 100)
	p.mu.Lock()
	p.SystemMetrics.ThermalState = "critical"
	p.mu.Unlock()

	if candidates, rejections, tooLarge := reg.QuickCapacityCheckForRequest(model, 100, 128, RequestTraits{}, false); candidates != 0 || rejections != 0 || tooLarge != 0 {
		t.Fatalf("critical thermal preflight = (%d,%d,%d), want 0/0/0", candidates, rejections, tooLarge)
	}
}

func TestIdleResidentAdmittedByFallbackMemoryGate(t *testing.T) {
	reg := New(testLogger())
	model := "idle-resident-fallback"
	reg.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 40}})
	p := makeSchedulerProvider(t, reg, "idle-resident", model, 100)
	p.mu.Lock()
	p.BackendCapacity.GPUMemoryActiveGB = 42
	p.BackendCapacity.TotalMemoryGB = 64
	p.BackendCapacity.Slots[0].State = "idle"
	// Force legacy memory admission path; active token budget path would bypass
	// the bug this test guards.
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 0
	p.mu.Unlock()

	selected, decision := reg.ReserveProviderEx(model, &PendingRequest{RequestID: "idle-resident", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 128})
	if selected == nil {
		t.Fatalf("idle resident provider rejected; decision=%+v", decision)
	}
	if selected.ID != p.ID {
		t.Fatalf("selected %q, want %q", selected.ID, p.ID)
	}
}
