package registry

import (
	"fmt"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestExecutionCalibrationCaptureSurvivesSlotReplacement(t *testing.T) {
	resetCalibrator(t)
	r := New(testLogger())
	p := calibrationTestProvider(t, r, "calibration-identity", "execution-calibration", 100, 1000)
	for i := 0; i < ttftCalibrationWarmupObs; i++ {
		p.mu.Lock()
		p.BackendCapacity.Slots[0] = protocol.BackendSlotCapacity{Model: "execution-calibration", State: "idle", MaxConcurrency: 4}
		p.mu.Unlock()
		req := &PendingRequest{RequestID: fmt.Sprintf("native-before-replacement-%d", i), Model: "execution-calibration", EstimatedPromptTokens: 100, RequestedMaxTokens: 1}
		selected, decision := r.ReserveProviderEx(req.Model, req)
		if selected == nil {
			t.Fatalf("native reserve failed %+v", decision)
		}
		p.mu.Lock()
		p.BackendCapacity.Slots[0].ExecutionIdentity = executionK4
		p.mu.Unlock()
		if _, ok := RecordTTFTObservation(req.RequestID, req.Attempt, 55); !ok {
			t.Fatal("completion lost captured identity")
		}
		p.RemovePending(req.RequestID)
		r.SetProviderIdle(p.ID)
	}
	if got := TTFTCalibrationRatio("execution-calibration", p.Hardware.ChipFamily); got != 0.5 {
		t.Fatalf("native ratio=%v", got)
	}
	for _, id := range []string{executionK4, executionK8V4} {
		if got := TTFTCalibrationRatio("execution-calibration", p.Hardware.ChipFamily, id); got != 1 {
			t.Fatalf("old completion trained %q: %v", id, got)
		}
	}
	for i := 0; i < ttftCalibrationWarmupObs; i++ {
		id := fmt.Sprintf("quant-only-%d", i)
		ttftCalibration.notePrediction(id, 0, "execution-calibration", "M4", 1000, executionK4)
		RecordTTFTObservation(id, 0, 1500)
	}
	if TTFTCalibrationRatio("execution-calibration", "M4", executionK4) != 1.5 || TTFTCalibrationRatio("execution-calibration", "M4", executionK8V4) != 1 {
		t.Fatal("quantized calibration partitions mixed")
	}
	if TTFTCalibrationRatio("execution-calibration", "other", executionK4) != 1.5 {
		t.Fatal("same-execution model aggregate unavailable")
	}
}
