package registry

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func testWarmPoolConfig() WarmPoolConfig {
	return WarmPoolConfig{
		Enabled:                   true,
		ObserveOnly:               false,
		Interval:                  time.Second,
		MinDwell:                  0,
		QueueAgeThreshold:         2 * time.Second,
		CapacityRejectThreshold:   1,
		WarmSaturationThreshold:   0.8,
		TTFTMissThreshold:         1,
		SpeculativeStartThreshold: 1,
		SpeculativeWinThreshold:   1,
		ColdDispatchThreshold:     1,
		LoadDurationThreshold:     time.Second,
		MaxLoadsPerTick:           1,
		MaxGlobalPendingLoads:     10,
	}
}

func makeWarmPoolColdProvider(t *testing.T, reg *Registry, id, model string, decodeTPS float64, totalMemory, activeMemory float64) *Provider {
	t.Helper()
	p := makeSchedulerProvider(t, reg, id, model, decodeTPS)
	p.mu.Lock()
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB:     totalMemory,
		GPUMemoryActiveGB: activeMemory,
		Slots: []protocol.BackendSlotCapacity{
			{Model: "other-model", State: "idle"},
		},
	}
	p.mu.Unlock()
	return p
}

func captureWarmPoolLoads(reg *Registry) *[]modelLoadAction {
	var sent []modelLoadAction
	reg.loadModelSender = func(providerID, modelID string) error {
		sent = append(sent, modelLoadAction{providerID: providerID, modelID: modelID})
		return nil
	}
	return &sent
}

func TestWarmPoolSaturatedWarmProviderRaisesTargetAndSendsBoundedLoad(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-saturated"
	warm := makeSchedulerProvider(t, reg, "warm", model, 80)
	cold := makeWarmPoolColdProvider(t, reg, "cold", model, 80, 64, 8)
	warm.mu.Lock()
	warm.BackendCapacity.Slots[0].MaxConcurrency = 1
	warm.BackendCapacity.Slots[0].NumRunning = 1
	warm.mu.Unlock()

	reg.ConfigureWarmPool(testWarmPoolConfig())
	sent := captureWarmPoolLoads(reg)
	reg.RecordWarmPoolCapacityReject(model)

	snaps := reg.warmPool.tick(time.Now())
	if len(*sent) != 1 {
		t.Fatalf("sent loads = %d, want 1", len(*sent))
	}
	if (*sent)[0].providerID != cold.ID || (*sent)[0].modelID != model {
		t.Fatalf("sent %+v, want cold provider/model", (*sent)[0])
	}
	if len(snaps) == 0 || snaps[0].TargetWarm < 2 || len(snaps[0].Actions) != 1 {
		t.Fatalf("snapshot = %+v, want target>=2 with one action", snaps)
	}
}

func TestWarmPoolCapacityRejectRaisesTargetWithoutQueue(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-capacity"
	makeSchedulerProvider(t, reg, "warm", model, 80)
	makeWarmPoolColdProvider(t, reg, "cold", model, 80, 64, 8)
	reg.ConfigureWarmPool(testWarmPoolConfig())
	sent := captureWarmPoolLoads(reg)

	reg.RecordWarmPoolCapacityReject(model)
	reg.warmPool.tick(time.Now())

	if len(*sent) != 1 {
		t.Fatalf("sent loads = %d, want 1", len(*sent))
	}
}

func TestWarmPoolQueueAgePressureRaisesTarget(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-queue-age"
	makeSchedulerProvider(t, reg, "warm", model, 80)
	makeWarmPoolColdProvider(t, reg, "cold", model, 80, 64, 8)
	reg.ConfigureWarmPool(testWarmPoolConfig())
	sent := captureWarmPoolLoads(reg)

	reg.RecordWarmPoolQueueEnqueued(model, 1, 3*time.Second)
	reg.warmPool.tick(time.Now())

	if len(*sent) != 1 {
		t.Fatalf("sent loads = %d, want 1", len(*sent))
	}
}

func TestTriggerWarmPoolRespondsToQueuePressureImmediately(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-immediate-queue"
	makeSchedulerProvider(t, reg, "warm", model, 80)
	makeWarmPoolColdProvider(t, reg, "cold", model, 80, 64, 8)
	cfg := testWarmPoolConfig()
	cfg.QueueAgeThreshold = 0
	reg.ConfigureWarmPool(cfg)
	sent := captureWarmPoolLoads(reg)

	reg.RecordWarmPoolQueueEnqueued(model, 1, 0)
	snaps := reg.TriggerWarmPool()

	if len(*sent) != 1 {
		t.Fatalf("sent loads = %d, want 1", len(*sent))
	}
	if len(snaps) == 0 || snaps[0].QueueDepth != 1 || len(snaps[0].Actions) != 1 {
		t.Fatalf("snapshot = %+v, want immediate queue-pressure action", snaps)
	}
}

func TestRequestWarmPoolTriggerCoalescesBursts(t *testing.T) {
	reg := New(testLogger())
	reg.ConfigureWarmPool(testWarmPoolConfig())

	if !reg.RequestWarmPoolTrigger() {
		t.Fatal("first trigger should enqueue a warm-pool tick")
	}
	for i := 0; i < 10; i++ {
		if reg.RequestWarmPoolTrigger() {
			t.Fatalf("trigger %d was accepted despite an already pending tick", i+2)
		}
	}
	if got := len(reg.warmPool.triggerC); got != 1 {
		t.Fatalf("pending triggers = %d, want 1", got)
	}
}

func TestWarmPoolQueueClearStopsStaleQueueLoads(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-clear-queue"
	makeSchedulerProvider(t, reg, "warm", model, 80)
	makeWarmPoolColdProvider(t, reg, "cold-a", model, 80, 64, 8)
	makeWarmPoolColdProvider(t, reg, "cold-b", model, 80, 64, 8)
	cfg := testWarmPoolConfig()
	cfg.QueueAgeThreshold = 0
	cfg.MaxGlobalPendingLoads = 10
	reg.ConfigureWarmPool(cfg)
	sent := captureWarmPoolLoads(reg)

	reg.RecordWarmPoolQueueEnqueued(model, 1, 0)
	reg.TriggerWarmPool()
	if len(*sent) != 1 {
		t.Fatalf("sent loads after queue pressure = %d, want 1", len(*sent))
	}

	reg.RecordWarmPoolQueueCleared(model)
	snaps := reg.TriggerWarmPool()
	if len(*sent) != 1 {
		t.Fatalf("sent loads after clearing queue = %d, want still 1", len(*sent))
	}
	if len(snaps) == 0 || snaps[0].QueueDepth != 0 || len(snaps[0].Actions) != 0 {
		t.Fatalf("snapshot after clear = %+v, want no queue-driven action", snaps)
	}
}

func TestTriggerWarmPoolObserveOnlyDoesNotSendLoads(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-observe-only"
	makeSchedulerProvider(t, reg, "warm", model, 80)
	makeWarmPoolColdProvider(t, reg, "cold", model, 80, 64, 8)
	cfg := testWarmPoolConfig()
	cfg.QueueAgeThreshold = 0
	cfg.ObserveOnly = true
	reg.ConfigureWarmPool(cfg)
	sent := captureWarmPoolLoads(reg)

	reg.RecordWarmPoolQueueEnqueued(model, 1, 0)
	snaps := reg.TriggerWarmPool()

	if len(*sent) != 0 {
		t.Fatalf("sent loads = %d, want 0 in observe-only mode", len(*sent))
	}
	if len(snaps) != 0 {
		t.Fatalf("snapshots = %+v, want no active trigger in observe-only mode", snaps)
	}
}

func TestWarmPoolNoPressureForLongActiveDecodeAlone(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-active-only"
	warm := makeSchedulerProvider(t, reg, "warm", model, 80)
	makeWarmPoolColdProvider(t, reg, "cold", model, 80, 64, 8)
	warm.mu.Lock()
	warm.BackendCapacity.Slots[0].NumRunning = 1
	warm.mu.Unlock()
	reg.ConfigureWarmPool(testWarmPoolConfig())
	sent := captureWarmPoolLoads(reg)

	snaps := reg.warmPool.tick(time.Now())

	if len(*sent) != 0 {
		t.Fatalf("sent loads = %d, want 0", len(*sent))
	}
	if len(snaps) == 0 || snaps[0].TargetWarm != 1 {
		t.Fatalf("snapshot = %+v, want target 1", snaps)
	}
}

func TestWarmPoolFleetSnapshotUsesObservedSlotTPS(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-observed-tps"
	p := makeSchedulerProvider(t, reg, "warm", model, 23)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].ObservedDecodeTPS = 73
	p.BackendCapacity.Slots[0].ObservedPrefillTPS = 1000
	p.mu.Unlock()

	snap := reg.warmPoolFleetSnapshot(time.Now())[model]

	if snap.soloDecodeTPS != 73 {
		t.Fatalf("soloDecodeTPS = %v, want observed slot TPS 73", snap.soloDecodeTPS)
	}
	if snap.prefillTPS != 1000 {
		t.Fatalf("prefillTPS = %v, want observed slot prefill TPS 1000", snap.prefillTPS)
	}
}

func TestWarmPoolFleetSnapshotFallsBackToStaticTPS(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-static-tps"
	makeSchedulerProvider(t, reg, "warm", model, 23)

	snap := reg.warmPoolFleetSnapshot(time.Now())[model]

	if snap.soloDecodeTPS != 23 {
		t.Fatalf("soloDecodeTPS = %v, want static TPS 23", snap.soloDecodeTPS)
	}
	if snap.prefillTPS != 23*PrefillToDecodeRatio() {
		t.Fatalf("prefillTPS = %v, want static fallback %v", snap.prefillTPS, 23*PrefillToDecodeRatio())
	}
}

func TestWarmPoolDiagnosticsReflectObservedTPS(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-observed-diagnostics"
	p := makeSchedulerProvider(t, reg, "warm", model, 23)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].ObservedDecodeTPS = 73
	p.BackendCapacity.Slots[0].ObservedPrefillTPS = 1000
	p.mu.Unlock()

	cfg := testWarmPoolConfig()
	cfg.DecodeFloorTPS = 15
	cfg.AssumedPromptTokens = 512
	cfg.AssumedCompletionTokens = 256
	reg.ConfigureWarmPool(cfg)
	reg.RecordWarmPoolCapacityReject(model)

	snaps := reg.warmPool.tick(time.Now())
	if len(snaps) != 1 {
		t.Fatalf("snapshots = %d, want 1", len(snaps))
	}
	snap := snaps[0]
	if snap.QualityConcurrency <= 2 {
		t.Fatalf("QualityConcurrency = %d, want observed TPS to raise it above stale value 2", snap.QualityConcurrency)
	}
	if snap.ServiceTime >= 10*time.Second {
		t.Fatalf("ServiceTime = %v, want observed TPS to keep it below stale 12.8s", snap.ServiceTime)
	}
}

func TestWarmPoolSkipsIneligibleProviders(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-skip"
	makeSchedulerProvider(t, reg, "warm", model, 80)
	priv := makeWarmPoolColdProvider(t, reg, "private", model, 80, 64, 8)
	untrusted := makeWarmPoolColdProvider(t, reg, "untrusted", model, 80, 64, 8)
	stale := makeWarmPoolColdProvider(t, reg, "stale", model, 80, 64, 8)
	critical := makeWarmPoolColdProvider(t, reg, "critical", model, 80, 64, 8)
	active := makeWarmPoolColdProvider(t, reg, "active", model, 80, 64, 8)
	pending := makeWarmPoolColdProvider(t, reg, "pending", model, 80, 64, 8)
	good := makeWarmPoolColdProvider(t, reg, "good", model, 80, 64, 8)

	priv.mu.Lock()
	priv.PrivateOnly = true
	priv.mu.Unlock()
	untrusted.mu.Lock()
	untrusted.Status = StatusUntrusted
	untrusted.mu.Unlock()
	stale.mu.Lock()
	// Stale beyond challengeFreshnessMaxAge (16m as of W5b Fix 4) so the warm-pool
	// controller treats this provider's attestation as expired and skips it.
	stale.LastChallengeVerified = time.Now().Add(-20 * time.Minute)
	stale.mu.Unlock()
	critical.mu.Lock()
	critical.SystemMetrics.ThermalState = "critical"
	critical.mu.Unlock()
	active.AddPending(&PendingRequest{RequestID: "active-req", Model: "other-model"})
	reg.reservePendingModelLoads([]modelLoadAction{{providerID: pending.ID, modelID: model}}, time.Now())

	reg.ConfigureWarmPool(testWarmPoolConfig())
	sent := captureWarmPoolLoads(reg)
	reg.RecordWarmPoolCapacityReject(model)
	reg.warmPool.tick(time.Now())

	if len(*sent) != 1 {
		t.Fatalf("sent loads = %d, want 1", len(*sent))
	}
	if (*sent)[0].providerID != good.ID {
		t.Fatalf("selected provider = %q, want good", (*sent)[0].providerID)
	}
}

func TestWarmPoolPicksBetterIdleProvider(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-score"
	makeSchedulerProvider(t, reg, "warm", model, 80)
	bad := makeWarmPoolColdProvider(t, reg, "bad", model, 40, 32, 28)
	good := makeWarmPoolColdProvider(t, reg, "good", model, 160, 128, 12)
	bad.mu.Lock()
	bad.SystemMetrics.ThermalState = "serious"
	bad.SystemMetrics.MemoryPressure = 0.7
	bad.mu.Unlock()

	reg.ConfigureWarmPool(testWarmPoolConfig())
	sent := captureWarmPoolLoads(reg)
	reg.RecordWarmPoolCapacityReject(model)
	reg.warmPool.tick(time.Now())

	if len(*sent) != 1 {
		t.Fatalf("sent loads = %d, want 1", len(*sent))
	}
	if (*sent)[0].providerID != good.ID {
		t.Fatalf("selected provider = %q, want %q", (*sent)[0].providerID, good.ID)
	}
}

// --- Little's Law target math (pure, warm_pool_target.go) ---

func TestQualityConcurrencyFromDecodeFloor(t *testing.T) {
	k := effectiveTPSLoadFactor // 0.27
	// solo 100, floor 15: B <= (100/15 - 1)/0.27 = 20.98 -> 20 (under cap 32).
	if got := qualityConcurrency(100, 15, k, 32, 4); got != 20 {
		t.Fatalf("qc(solo100,floor15,cap32) = %d, want 20", got)
	}
	// Capped by the provider concurrency limit.
	if got := qualityConcurrency(100, 15, k, 6, 4); got != 6 {
		t.Fatalf("qc capped = %d, want 6", got)
	}
	// Solo at/below floor -> only one request per provider keeps quality.
	if got := qualityConcurrency(10, 15, k, 8, 4); got != 1 {
		t.Fatalf("qc(solo10,floor15) = %d, want 1", got)
	}
	// Floor disabled -> constraint does not bind, return the cap.
	if got := qualityConcurrency(100, 0, k, 8, 4); got != 8 {
		t.Fatalf("qc(floor=0) = %d, want 8 (cap)", got)
	}
	// Unknown cap -> fallback concurrency.
	if got := qualityConcurrency(100, 0, k, 0, 4); got != 4 {
		t.Fatalf("qc(no cap) = %d, want 4 (fallback)", got)
	}
}

func TestWarmTargetLittlesLaw(t *testing.T) {
	params := warmTargetParams{
		DecodeFloorTPS:             15,
		LoadFactorK:                effectiveTPSLoadFactor,
		BurstBuffer:                0,
		FallbackQualityConcurrency: 4,
		MinServiceTime:             warmPoolMinServiceTime,
		MaxServiceTime:             warmPoolMaxServiceTime,
	}
	// Served L=8 (in-flight), qc=1 (solo 20 vs floor 15) -> target ceil(8/1)=8.
	served := warmTargetInputs{
		Warm: 1, EligibleCold: 20, RunningRequests: 8,
		SoloDecodeTPS: 20, MaxProviderConc: 6, DemandPressure: true,
	}
	if got := warmTarget(served, params, time.Second); got != 8 {
		t.Fatalf("warmTarget(served) = %d, want 8", got)
	}
	// No demand pressure -> leave the pool at its current warm count.
	noPressure := served
	noPressure.DemandPressure = false
	if got := warmTarget(noPressure, params, time.Second); got != 1 {
		t.Fatalf("warmTarget(no pressure) = %d, want 1", got)
	}
	// Spill-driven: 2 req/s * E[S] 5s = 10 concurrent, qc=1 -> target 10.
	spill := warmTargetInputs{
		Warm: 0, EligibleCold: 20, SpillArrivalRate: 2.0,
		SoloDecodeTPS: 20, MaxProviderConc: 6, DemandPressure: true,
	}
	if got := warmTarget(spill, params, 5*time.Second); got != 10 {
		t.Fatalf("warmTarget(spill) = %d, want 10", got)
	}
	// Never exceed what the fleet can warm (warm + eligibleCold).
	capped := spill
	capped.EligibleCold = 3
	if got := warmTarget(capped, params, 5*time.Second); got != 3 {
		t.Fatalf("warmTarget(capped) = %d, want 3", got)
	}
	// A lone pressure event still nudges the pool forward by one (reactive floor).
	reactive := warmTargetInputs{
		Warm: 2, EligibleCold: 5, SoloDecodeTPS: 100, MaxProviderConc: 8, DemandPressure: true,
	}
	if got := warmTarget(reactive, params, time.Second); got != 3 {
		t.Fatalf("warmTarget(reactive floor) = %d, want 3", got)
	}
}

func TestRampLoadsThisTickDemandScaled(t *testing.T) {
	// Small gap is capped by the gap itself.
	if got := rampLoadsThisTick(1, 2, 16, 0.5); got != 1 {
		t.Fatalf("ramp(gap1) = %d, want 1", got)
	}
	// Gap at/below base burst -> base, capped by gap.
	if got := rampLoadsThisTick(5, 4, 16, 0.5); got != 4 {
		t.Fatalf("ramp(gap5,base4) = %d, want 4", got)
	}
	// Large gap -> fraction scales the burst above the base.
	if got := rampLoadsThisTick(20, 4, 16, 0.5); got != 10 {
		t.Fatalf("ramp(gap20,frac.5) = %d, want 10", got)
	}
	// Hard ceiling bounds the burst.
	if got := rampLoadsThisTick(100, 4, 16, 0.5); got != 16 {
		t.Fatalf("ramp(gap100) = %d, want 16 (ceiling)", got)
	}
	// Fraction 0 falls back to the flat base burst.
	if got := rampLoadsThisTick(20, 3, 16, 0); got != 3 {
		t.Fatalf("ramp(frac0) = %d, want 3 (base)", got)
	}
	// No gap -> no loads.
	if got := rampLoadsThisTick(0, 4, 16, 1.0); got != 0 {
		t.Fatalf("ramp(gap0) = %d, want 0", got)
	}
}

func TestEstimateServiceTimeClamped(t *testing.T) {
	p := warmTargetParams{
		AssumedPromptTokens:     600,
		AssumedCompletionTokens: 256,
		MinServiceTime:          warmPoolMinServiceTime,
		MaxServiceTime:          warmPoolMaxServiceTime,
	}
	// prefill 600/600 = 1s + decode 256/50 = 5.12s ~= 6.12s.
	svc := estimateServiceTime(600, 50, p)
	if svc < 6*time.Second || svc > 7*time.Second {
		t.Fatalf("svc = %v, want ~6.12s", svc)
	}
	// Near-zero rates blow up E[S] -> clamp to the max.
	if got := estimateServiceTime(0.001, 0.001, p); got != warmPoolMaxServiceTime {
		t.Fatalf("svc(tiny rates) = %v, want max %v", got, warmPoolMaxServiceTime)
	}
	// Zero assumed tokens -> clamp to the min.
	p2 := p
	p2.AssumedPromptTokens = 0
	p2.AssumedCompletionTokens = 0
	if got := estimateServiceTime(50, 50, p2); got != warmPoolMinServiceTime {
		t.Fatalf("svc(zero tokens) = %v, want min %v", got, warmPoolMinServiceTime)
	}
}

func TestMedianFloat(t *testing.T) {
	if got := medianFloat(nil); got != 0 {
		t.Fatalf("median(nil) = %v, want 0", got)
	}
	if got := medianFloat([]float64{20}); got != 20 {
		t.Fatalf("median([20]) = %v, want 20", got)
	}
	if got := medianFloat([]float64{30, 10, 20}); got != 20 {
		t.Fatalf("median(odd) = %v, want 20", got)
	}
	if got := medianFloat([]float64{10, 20, 30, 40}); got != 25 {
		t.Fatalf("median(even) = %v, want 25", got)
	}
}

// --- Arrival-rate EWMA (warm_pool_state.go) ---

func TestWarmPoolFoldArrivalRates(t *testing.T) {
	s := newWarmPoolState()
	model := "arrival"
	t0 := time.Now()
	for i := 0; i < 10; i++ {
		s.recordEvent(model, warmPoolEventCapacityReject, t0)
	}
	// First fold only establishes the baseline timestamp; no rate yet.
	s.foldArrivalRates(t0, time.Second, 1.0)
	if got := s.snapshot(t0, time.Minute)[model].arrivalRateEWMA; got != 0 {
		t.Fatalf("first fold rate = %v, want 0", got)
	}
	// 10 spill arrivals accumulated; folding 10s later with alpha=1 yields the
	// instantaneous rate 10/10 = 1.0 req/s.
	t1 := t0.Add(10 * time.Second)
	s.foldArrivalRates(t1, time.Second, 1.0)
	if got := s.snapshot(t1, time.Minute)[model].arrivalRateEWMA; got != 1.0 {
		t.Fatalf("folded rate = %v, want 1.0", got)
	}
	// Non-spill signals (speculative) do not inflate the arrival rate.
	s2 := newWarmPoolState()
	s2.recordEvent(model, warmPoolEventSpeculativeStarted, t0)
	s2.foldArrivalRates(t0, time.Second, 1.0)
	s2.foldArrivalRates(t0.Add(10*time.Second), time.Second, 1.0)
	if got := s2.snapshot(t0.Add(10*time.Second), time.Minute)[model].arrivalRateEWMA; got != 0 {
		t.Fatalf("speculative arrival rate = %v, want 0", got)
	}
}

// --- Controller integration: Little's Law + demand-scaled ramp ---

func TestWarmPoolLittlesLawDemandScaledRamp(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-littles-law"
	// One warm provider overloaded with 8 in-flight requests; with a 15 tok/s
	// floor and a 20 tok/s solo rate, per-provider quality concurrency is 1, so
	// Little's Law wants 8 warm providers to serve the in-flight load at quality.
	warm := makeSchedulerProvider(t, reg, "warm", model, 20)
	warm.mu.Lock()
	warm.BackendCapacity.Slots[0].NumRunning = 8
	warm.mu.Unlock()
	for i := 0; i < 8; i++ {
		makeWarmPoolColdProvider(t, reg, fmt.Sprintf("cold-%d", i), model, 20, 64, 8)
	}

	cfg := testWarmPoolConfig()
	cfg.DecodeFloorTPS = 15
	cfg.BurstBuffer = 0
	cfg.MaxLoadsPerTick = 2
	cfg.MaxLoadsPerTickCeiling = 16
	cfg.RampGapFraction = 1.0
	cfg.MaxGlobalPendingLoads = 20
	reg.ConfigureWarmPool(cfg)
	sent := captureWarmPoolLoads(reg)
	reg.RecordWarmPoolCapacityReject(model)

	snaps := reg.warmPool.tick(time.Now())
	if len(snaps) == 0 {
		t.Fatal("no warm-pool snapshot produced")
	}
	s := snaps[0]
	if s.QualityConcurrency != 1 {
		t.Fatalf("QualityConcurrency = %d, want 1", s.QualityConcurrency)
	}
	if s.RunningRequests != 8 {
		t.Fatalf("RunningRequests = %d, want 8", s.RunningRequests)
	}
	if s.TargetWarm != 8 {
		t.Fatalf("TargetWarm = %d, want 8 (L=8 served / qc=1)", s.TargetWarm)
	}
	// Demand-scaled ramp closes the whole gap (target 8 - warm 1 = 7) in one
	// tick, far above the flat MaxLoadsPerTick=2 baseline — bounded by the
	// per-tick ceiling (16) and the eligible cold pool (8).
	if len(*sent) != 7 {
		t.Fatalf("sent loads = %d, want 7 (demand-scaled ramp)", len(*sent))
	}
}

func TestWarmPoolRampBoundedByCeiling(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-ramp-ceiling"
	warm := makeSchedulerProvider(t, reg, "warm", model, 20)
	warm.mu.Lock()
	warm.BackendCapacity.Slots[0].NumRunning = 20
	warm.mu.Unlock()
	for i := 0; i < 12; i++ {
		makeWarmPoolColdProvider(t, reg, fmt.Sprintf("cold-%d", i), model, 20, 64, 8)
	}

	cfg := testWarmPoolConfig()
	cfg.DecodeFloorTPS = 15 // qc = 1 -> target tracks the 20 in-flight requests
	cfg.BurstBuffer = 0
	cfg.MaxLoadsPerTick = 2
	cfg.MaxLoadsPerTickCeiling = 5 // hard per-tick maximum
	cfg.RampGapFraction = 1.0
	cfg.MaxGlobalPendingLoads = 50
	reg.ConfigureWarmPool(cfg)
	sent := captureWarmPoolLoads(reg)
	reg.RecordWarmPoolCapacityReject(model)

	snaps := reg.warmPool.tick(time.Now())
	if len(snaps) == 0 || snaps[0].TargetWarm < 13 {
		t.Fatalf("snapshot = %+v, want target >= 13", snaps)
	}
	// Gap is large (>= 12) but the per-tick ceiling caps the burst at 5.
	if len(*sent) != 5 {
		t.Fatalf("sent loads = %d, want 5 (ceiling-bounded)", len(*sent))
	}
}
