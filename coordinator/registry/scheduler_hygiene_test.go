package registry

import (
	"fmt"
	"testing"
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
