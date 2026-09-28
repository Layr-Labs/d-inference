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

// The historical learned TTFT ratio remains a diagnostic. It must never turn
// missing or stale performance evidence into credible admission certainty.
func TestTTFTCalibrationDoesNotChangeFirstContentConfidence(t *testing.T) {
	for _, factor := range []float64{0.3, 2} {
		t.Run(fmt.Sprintf("factor-%v", factor), func(t *testing.T) {
			resetCalibrator(t)
			reg := New(testLogger())
			model := "calibration-diagnostic"
			calibrationTestProvider(t, reg, "provider", model, 100, 100)
			const rawEstimateMs = 10010.0
			request := func(id string) *PendingRequest {
				return &PendingRequest{RequestID: id, Model: model, EstimatedPromptTokens: 1000,
					RequestedMaxTokens: 128, MaxTTFTMs: 5000, FirstContentDeadline: time.Now().Add(5 * time.Second)}
			}
			reserve := func(id string) RoutingDecision {
				p, d := reg.ReserveProviderEx(model, request(id))
				if p == nil || d.FirstContent.Status != FirstContentUnknown || d.TTFTRejections != 0 {
					t.Fatalf("calibration cannot certify unknown samples: provider=%v forecast=%+v rejects=%d", p != nil, d.FirstContent, d.TTFTRejections)
				}
				p.RemovePending(id)
				reg.SetProviderIdle(p.ID)
				return d
			}
			before := reserve("before")
			feedCalibrationThroughScheduler(t, reg, model, 1000, ttftCalibrationWarmupObs, rawEstimateMs*factor)
			after := reserve("after")
			want := rawEstimateMs * min(factor, 1.5)
			if math.Abs(after.TTFTMs-want) > 1 {
				t.Fatalf("learned diagnostic=%v, want %v", after.TTFTMs, want)
			}
			if after.FirstContent.ExpectedMs != before.FirstContent.ExpectedMs || after.FirstContent.ConservativeMs != before.FirstContent.ConservativeMs {
				t.Fatal("historical mean calibration changed independent first-content work forecast")
			}
			t.Setenv("EIGENINFERENCE_TTFT_CALIBRATION", "off")
			disabled := reserve("disabled")
			if math.Abs(disabled.TTFTMs-rawEstimateMs) > 1 {
				t.Fatalf("disabled diagnostic=%v, want %v", disabled.TTFTMs, rawEstimateMs)
			}
		})
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

func TestTTFTCalibrationSkipsVisionPredictions(t *testing.T) {
	resetCalibrator(t)
	reg := New(testLogger())
	model := "calib-vision-model"
	p := calibrationTestProvider(t, reg, "vision-box", model, 100, 100)
	p.mu.Lock()
	p.Models[0].IsVision = true
	p.mu.Unlock()

	req := &PendingRequest{
		RequestID:             "vision-req",
		Model:                 model,
		EstimatedPromptTokens: 200,
		RequestedMaxTokens:    128,
		RequiresVision:        true,
	}
	selected, decision := reg.ReserveProviderEx(model, req)
	if selected == nil {
		t.Fatalf("vision reserve failed: %+v", decision)
	}
	if _, ok := RecordTTFTObservation(req.RequestID, req.Attempt, 2_000); ok {
		t.Fatal("vision prediction must not train the text-prefill calibrator")
	}
	selected.RemovePending(req.RequestID)
}
