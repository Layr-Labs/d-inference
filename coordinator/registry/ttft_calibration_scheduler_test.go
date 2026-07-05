package registry

import (
	"fmt"
	"math"
	"testing"
	"time"
)

// calibrationTestProvider builds a warm provider whose raw TTFT estimate for a
// promptTokens-request is exactly promptTokens/prefillTPS*1000 + 1000/decodeTPS
// (warm slot, no waiting queue, no observed EWMAs).
func calibrationTestProvider(t *testing.T, reg *Registry, id, model string, decodeTPS, prefillTPS float64) *Provider {
	t.Helper()
	p := makeSchedulerProvider(t, reg, id, model, decodeTPS)
	p.mu.Lock()
	p.PrefillTPS = prefillTPS
	p.mu.Unlock()
	return p
}

// feedCalibrationThroughScheduler runs n reserve→observe cycles through the
// REAL paths: ReserveProviderEx notes the raw prediction, and
// RecordTTFTObservation joins the measured actual to it.
func feedCalibrationThroughScheduler(t *testing.T, reg *Registry, model string, promptTokens, n int, actualMs float64) {
	t.Helper()
	for i := 0; i < n; i++ {
		req := &PendingRequest{
			RequestID:             fmt.Sprintf("calib-feed-%d", i),
			Model:                 model,
			EstimatedPromptTokens: promptTokens,
			RequestedMaxTokens:    128,
		}
		selected, decision := reg.ReserveProviderEx(model, req)
		if selected == nil {
			t.Fatalf("feed reserve %d failed: %+v", i, decision)
		}
		if _, ok := RecordTTFTObservation(req.RequestID, req.Attempt, actualMs); !ok {
			t.Fatalf("feed observation %d not recorded", i)
		}
		selected.RemovePending(req.RequestID)
		reg.SetProviderIdle(selected.ID)
	}
}

// A provider whose raw estimate is ~3x reality (the production gpt-oss shape)
// hard-rejects a request it could serve; after the calibrator learns the true
// ratio from completed requests, the same request passes the gate — and the
// kill switch restores the uncalibrated behavior live.
func TestTTFTCalibrationUnblocksHardRejectGate(t *testing.T) {
	resetCalibrator(t)
	reg := New(testLogger())
	model := "calib-overpredict-model"
	// prompt 1000 / prefill 100 tok/s => raw estimate 10010ms.
	calibrationTestProvider(t, reg, "over-estimator", model, 100, 100)
	const promptTokens = 1000
	const rawEstimateMs = 10_010.0
	const ceilingMs = 5_000.0

	gatedReq := func(id string) *PendingRequest {
		return &PendingRequest{
			RequestID:             id,
			Model:                 model,
			EstimatedPromptTokens: promptTokens,
			RequestedMaxTokens:    128,
			MaxTTFTMs:             ceilingMs,
		}
	}

	// Uncalibrated: the raw 10s estimate exceeds the 5s ceiling.
	selected, decision := reg.ReserveProviderEx(model, gatedReq("calib-before"))
	if selected != nil {
		t.Fatalf("uncalibrated reserve selected %q, want TTFT rejection", selected.ID)
	}
	if decision.TTFTRejections != 1 {
		t.Fatalf("uncalibrated TTFTRejections = %d, want 1", decision.TTFTRejections)
	}
	if math.Abs(decision.BestTTFTMs-rawEstimateMs) > 1 {
		t.Fatalf("uncalibrated BestTTFTMs = %f, want ~%f", decision.BestTTFTMs, rawEstimateMs)
	}
	_, _, _, bestTTFT, hasTTFT := reg.QuickCapacityCheckWithTTFTForRequest(model, promptTokens, 128, RequestTraits{}, false)
	if !hasTTFT || math.Abs(float64(bestTTFT.Milliseconds())-rawEstimateMs) > 5 {
		t.Fatalf("uncalibrated preflight bestTTFT = %v, want ~%vms", bestTTFT, rawEstimateMs)
	}

	// Reality: first content lands in a third of the estimate.
	feedCalibrationThroughScheduler(t, reg, model, promptTokens, ttftCalibrationWarmupObs, rawEstimateMs*0.3)

	// Calibrated: 10010 x 0.3 = 3003ms clears the 5s ceiling.
	selected, decision = reg.ReserveProviderEx(model, gatedReq("calib-after"))
	if selected == nil {
		t.Fatalf("calibrated reserve rejected: %+v", decision)
	}
	if math.Abs(decision.TTFTMs-rawEstimateMs*0.3) > 1 {
		t.Fatalf("calibrated TTFTMs = %f, want ~%f", decision.TTFTMs, rawEstimateMs*0.3)
	}
	selected.RemovePending("calib-after")
	reg.SetProviderIdle(selected.ID)

	// The preflight consumes the same calibrated estimate.
	_, _, _, bestTTFT, hasTTFT = reg.QuickCapacityCheckWithTTFTForRequest(model, promptTokens, 128, RequestTraits{}, false)
	if !hasTTFT || math.Abs(float64(bestTTFT.Milliseconds())-rawEstimateMs*0.3) > 5 {
		t.Fatalf("calibrated preflight bestTTFT = %v, want ~%vms", bestTTFT, time.Duration(rawEstimateMs*0.3)*time.Millisecond)
	}

	// Kill switch: live env flip restores the uncalibrated gate.
	t.Setenv("EIGENINFERENCE_TTFT_CALIBRATION", "off")
	selected, decision = reg.ReserveProviderEx(model, gatedReq("calib-killed"))
	if selected != nil {
		t.Fatalf("kill-switched reserve selected %q, want TTFT rejection", selected.ID)
	}
	if decision.TTFTRejections != 1 {
		t.Fatalf("kill-switched TTFTRejections = %d, want 1", decision.TTFTRejections)
	}
}

// The reverse direction: a provider whose estimate is optimistic (actuals run
// 2x the prediction) initially passes the gate; after the calibrator learns
// upward (clamped at 1.5x), the same request is TTFT-rejected.
func TestTTFTCalibrationLearnsUpward(t *testing.T) {
	resetCalibrator(t)
	reg := New(testLogger())
	model := "calib-underpredict-model"
	// prompt 400 / prefill 100 tok/s => raw estimate 4010ms, under the ceiling.
	calibrationTestProvider(t, reg, "under-estimator", model, 100, 100)
	const promptTokens = 400
	const rawEstimateMs = 4_010.0
	const ceilingMs = 5_000.0

	req := &PendingRequest{
		RequestID:             "under-before",
		Model:                 model,
		EstimatedPromptTokens: promptTokens,
		RequestedMaxTokens:    128,
		MaxTTFTMs:             ceilingMs,
	}
	selected, decision := reg.ReserveProviderEx(model, req)
	if selected == nil {
		t.Fatalf("uncalibrated reserve rejected: %+v", decision)
	}
	selected.RemovePending(req.RequestID)
	reg.SetProviderIdle(selected.ID)

	// Reality is 2x the estimate; the learned ratio clamps to 1.5 at apply.
	feedCalibrationThroughScheduler(t, reg, model, promptTokens, ttftCalibrationWarmupObs, rawEstimateMs*2)

	// 4010 x 1.5 = 6015ms breaches the 5s ceiling.
	req = &PendingRequest{
		RequestID:             "under-after",
		Model:                 model,
		EstimatedPromptTokens: promptTokens,
		RequestedMaxTokens:    128,
		MaxTTFTMs:             ceilingMs,
	}
	selected, decision = reg.ReserveProviderEx(model, req)
	if selected != nil {
		t.Fatalf("calibrated reserve selected %q, want TTFT rejection", selected.ID)
	}
	if decision.TTFTRejections != 1 {
		t.Fatalf("calibrated TTFTRejections = %d, want 1", decision.TTFTRejections)
	}
	if math.Abs(decision.BestTTFTMs-rawEstimateMs*1.5) > 1 {
		t.Fatalf("calibrated BestTTFTMs = %f, want ~%f (clamped 1.5x)", decision.BestTTFTMs, rawEstimateMs*1.5)
	}
}

// Cold-slot reservations must not feed the calibrator: their actuals include
// model-load time the flow estimate does not model.
func TestTTFTCalibrationSkipsColdPredictions(t *testing.T) {
	resetCalibrator(t)
	reg := New(testLogger())
	model := "calib-cold-model"
	p := calibrationTestProvider(t, reg, "cold-box", model, 100, 100)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].State = "idle_shutdown"
	p.mu.Unlock()

	req := &PendingRequest{
		RequestID:             "cold-req",
		Model:                 model,
		EstimatedPromptTokens: 200,
		RequestedMaxTokens:    128,
	}
	selected, _ := reg.ReserveProviderEx(model, req)
	if selected == nil {
		t.Fatal("cold reserve failed")
	}
	if _, ok := RecordTTFTObservation(req.RequestID, req.Attempt, 25_000); ok {
		t.Fatal("cold-slot prediction must not be joinable")
	}
}
