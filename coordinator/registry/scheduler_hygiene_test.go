package registry

import (
	"fmt"
	"testing"
	"time"
)

// Scan/commit hygiene: environment reads hoisted to once per walk and the
// calibrator join moved after the registry write section.

// TestCalibrationSwitchReadOncePerWalk: the TTFT calibration kill switch is
// read once per fleet walk and scored into every candidate. With a learned
// ratio in place, the switch flips the ratio every candidate is scored with
// (and the profiler records) between walks.
func TestCalibrationSwitchReadOncePerWalk(t *testing.T) {
	ttftCalibration.reset()
	t.Cleanup(ttftCalibration.reset)
	reg := New(testLogger())
	model := "hygiene-calibration-model"
	makeSchedulerProvider(t, reg, "cal-a", model, 100)
	makeSchedulerProvider(t, reg, "cal-b", model, 100)
	// Learn a ratio of 2.0 for the model (chip-level and model-level windows),
	// past the calibrator's warm-up observation count.
	for i := 0; i < ttftCalibrationWarmupObs+2; i++ {
		id := fmt.Sprintf("learn-%d", i)
		ttftCalibration.notePrediction(id, 0, model, "M3", 100)
		ttftCalibration.recordActual(id, 0, 200)
	}
	if got := ttftCalibration.appliedRatioIf(true, model, "M3"); got == 1.0 {
		t.Fatalf("fixture: no learned ratio (got %v)", got)
	}

	reserve := func(id string) RoutingDecision {
		pr := &PendingRequest{RequestID: id, Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 100}
		p, decision := reg.ReserveProviderEx(model, pr)
		if p == nil {
			t.Fatalf("reservation failed: %+v", decision)
		}
		p.RemovePending(pr.RequestID)
		return decision
	}
	t.Setenv("EIGENINFERENCE_TTFT_CALIBRATION", "on")
	if d := reserve("cal-on"); d.TTFTCalibrationRatio == 1.0 {
		t.Fatalf("switch on: winner scored with ratio %v, want the learned ratio", d.TTFTCalibrationRatio)
	}
	t.Setenv("EIGENINFERENCE_TTFT_CALIBRATION", "off")
	if d := reserve("cal-off"); d.TTFTCalibrationRatio != 1.0 {
		t.Fatalf("switch off: winner scored with ratio %v, want 1.0 (the next walk re-reads the environment)", d.TTFTCalibrationRatio)
	}
	// The per-candidate form with the switch supplied directly.
	if ttftCalibration.appliedRatioIf(false, model, "M3") != 1.0 {
		t.Fatal("appliedRatioIf(false) must ignore the learned ratio")
	}
}

// TestDecodeFloorMedianSwitchReadOncePerWalk: the decode-floor fleet-median
// switch is read once per walk; the MinDecodeTPS narrowing sees the same
// value for every candidate.
func TestDecodeFloorMedianSwitchReadOncePerWalk(t *testing.T) {
	snap := &routingSnapshot{decodeTPS: 40, fleetMedianTPS: 9, backendRunning: 0}
	// Solo rate is divided by (1 + k) for the joining request in both tiers.
	k := effectiveTPSLoadFactor
	on := projectedPerRequestDecodeTPSWith(snap, true)
	off := projectedPerRequestDecodeTPSWith(snap, false)
	if on != projectedPerRequestDecodeTPSAtBatchWith(snap, 0, true) || on != 9/(1+k) {
		t.Fatalf("median on: projected=%v, want the 9 tok/s fleet median tier (%v)", on, 9/(1+k))
	}
	if off != projectedPerRequestDecodeTPSAtBatchWith(snap, 0, false) || off != 40/(1+k) {
		t.Fatalf("median off: projected=%v, want the static tier (%v)", off, 40/(1+k))
	}
	t.Setenv("EIGENINFERENCE_DECODE_FLOOR_USE_FLEET_MEDIAN", "false")
	if projectedPerRequestDecodeTPS(snap) != projectedPerRequestDecodeTPSWith(snap, false) {
		t.Fatal("the env-reading form must agree with the explicit switch")
	}
}

// TestPredictionNotedAfterReservationReturns: the calibrator join now runs
// after the registry write section on both reservation paths; the prediction
// must still be present when the reservation returns so first content can
// join it (RecordTTFTObservation matches).
func TestPredictionNotedAfterReservationReturns(t *testing.T) {
	ttftCalibration.reset()
	t.Cleanup(ttftCalibration.reset)
	reg := New(testLogger())
	model := "hygiene-prediction-model"
	for i := range 3 {
		planTestProvider(t, reg, "pred-"+string(rune('a'+i)), model, int64(i)*400)
	}
	pr := planTestRequest("pred-primary", 100, 100)
	pr.Model = model
	p, decision, plan := reg.ReserveProviderWithPlan(model, pr)
	if p == nil || plan == nil {
		t.Fatalf("reservation failed: %+v", decision)
	}
	if _, ok := RecordTTFTObservation(pr.RequestID, pr.Attempt, 150); !ok {
		t.Fatal("primary path: no pending prediction after ReserveProviderWithPlan returned")
	}
	p.RemovePending(pr.RequestID)

	retry := planTestRequest("pred-retry", 100, 100)
	retry.Model = model
	retry.Attempt = 1
	next, _, skips := reg.ReserveNextFromPlan(retry, plan, p.ID)
	if next == nil {
		t.Fatalf("plan path: no reservation (skips=%v)", skips)
	}
	if _, ok := RecordTTFTObservation(retry.RequestID, retry.Attempt, 150); !ok {
		t.Fatal("plan path: no pending prediction after ReserveNextFromPlan returned")
	}
	next.RemovePending(retry.RequestID)
}

// TestPreflightCalibrationSwitchReadOncePerWalk: the capacity preflight's
// bestTTFT is calibrated with the switch read once per walk, and follows the
// environment between walks exactly like the reservation scan.
func TestPreflightCalibrationSwitchReadOncePerWalk(t *testing.T) {
	ttftCalibration.reset()
	t.Cleanup(ttftCalibration.reset)
	reg := New(testLogger())
	model := "hygiene-preflight-model"
	makeSchedulerProvider(t, reg, "pre-a", model, 100)
	for i := 0; i < ttftCalibrationWarmupObs+2; i++ {
		id := fmt.Sprintf("pre-learn-%d", i)
		ttftCalibration.notePrediction(id, 0, model, "M3", 100)
		ttftCalibration.recordActual(id, 0, 200)
	}
	best := func() time.Duration {
		_, _, _, ttft, ok := reg.QuickCapacityCheckWithTTFTForRequest(model, 100, 100, RequestTraits{}, false)
		if !ok {
			t.Fatal("preflight reported no TTFT")
		}
		return ttft
	}
	t.Setenv("EIGENINFERENCE_TTFT_CALIBRATION", "off")
	raw := best()
	t.Setenv("EIGENINFERENCE_TTFT_CALIBRATION", "on")
	calibrated := best()
	if calibrated <= raw {
		t.Fatalf("calibrated bestTTFT %v <= raw %v: the learned 2.0 ratio must apply with the switch on", calibrated, raw)
	}
	reg.mu.RLock()
	snap, _ := reg.snapshotProviderLockedEx(reg.providers["pre-a"], model, RequestTraits{}, false, false, time.Now())
	reg.mu.RUnlock()
	if got := estimatedTTFTFromSnapshot(&snap, 100, false); got != raw {
		t.Fatalf("explicit switch off = %v, want the raw estimate %v", got, raw)
	}
}

// TestScanSwitchesReadOncePerWalkRegardlessOfFleetSize is the structural
// pin behind the three *ReadOncePerWalk tests above (which only prove the
// environment is honoured between walks): the number of live environment
// reads per reservation and per capacity preflight does not grow with the
// number of candidates walked. Fails if either switch is read inside the
// candidate loop again.
func TestScanSwitchesReadOncePerWalkRegardlessOfFleetSize(t *testing.T) {
	readsFor := func(providers int) (reserve, preflight int64) {
		reg := New(testLogger())
		model := fmt.Sprintf("hygiene-reads-%d", providers)
		for i := 0; i < providers; i++ {
			makeSchedulerProvider(t, reg, fmt.Sprintf("reads-%d-%d", providers, i), model, 100)
		}
		pr := &PendingRequest{RequestID: "reads-req", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 100}
		before := schedulerEnvReads.Load()
		p, decision := reg.ReserveProviderEx(model, pr)
		if p == nil {
			t.Fatalf("%d providers: reservation failed: %+v", providers, decision)
		}
		if decision.Rescans != 0 {
			t.Fatalf("%d providers: %d rescans, want 0 (each rescan is a walk of its own)", providers, decision.Rescans)
		}
		reserve = schedulerEnvReads.Load() - before
		p.RemovePending(pr.RequestID)
		before = schedulerEnvReads.Load()
		reg.QuickCapacityCheckForRequest(model, 100, 100, RequestTraits{}, false)
		preflight = schedulerEnvReads.Load() - before
		return reserve, preflight
	}
	r1, q1 := readsFor(1)
	r16, q16 := readsFor(16)
	t.Logf("env reads per reservation: 1 provider=%d 16 providers=%d; per preflight: %d / %d", r1, r16, q1, q16)
	if r1 == 0 || q1 == 0 {
		t.Fatal("fixture: the walk must read each switch at least once")
	}
	if r16 != r1 {
		t.Fatalf("reservation env reads grew with the fleet: 1 provider=%d, 16 providers=%d (read per candidate again)", r1, r16)
	}
	if q16 != q1 {
		t.Fatalf("preflight env reads grew with the fleet: 1 provider=%d, 16 providers=%d (read per candidate again)", q1, q16)
	}
}
