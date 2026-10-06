package inference_test

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	failure "github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type predictiveAdmissionObservation struct {
	provider       string
	requestID      string
	predictedMS    float64
	originalMS     int
	ceilingMS      float64
	wireMS         int64
	absoluteExpiry time.Time
}

func observePredictiveAdmission(
	t *testing.T, reg *registry.Registry, fp *failoverProvider, req protocol.InferenceRequestMessage,
) predictiveAdmissionObservation {
	t.Helper()
	p := reg.GetProvider(fp.registryID)
	if p == nil {
		t.Errorf("provider %q disappeared", fp.name)
		return predictiveAdmissionObservation{}
	}
	pr := p.GetPending(req.RequestID)
	if pr == nil || pr.Profile == nil || pr.Profile.Parent() == nil || !pr.Profile.DecisionSet {
		t.Errorf("dispatched request %q has no pending decision/profile", req.RequestID)
		return predictiveAdmissionObservation{}
	}
	mode, bypass, ceiling, budget := pr.Profile.PredictionObservation()
	if mode != "soft" || bypass != registry.PredictiveBypassNone || ceiling == nil || *ceiling != 0 || budget == nil || *budget != req.FirstContentBudgetMS {
		t.Errorf("missing actual soft dispatch observation: mode=%q bypass=%q ceiling=%v budget=%v wire=%d", mode, bypass, ceiling, budget, req.FirstContentBudgetMS)
	}
	// The dispatch goroutine publishes these values before the writer sends
	// the frame; the scripted provider has received it but has not replied.
	return predictiveAdmissionObservation{
		provider: fp.name, requestID: req.RequestID, predictedMS: pr.Profile.Decision.TTFTMs,
		originalMS: pr.Profile.Parent().FirstContentBudgetMs,
		ceilingMS:  pr.MaxTTFTMs, wireMS: req.FirstContentBudgetMS,
		absoluteExpiry: pr.FirstContentDeadline,
	}
}

func assertSoftOverBudgetDispatch(t *testing.T, got predictiveAdmissionObservation) {
	t.Helper()
	if got.originalMS <= 0 || got.predictedMS <= float64(got.originalMS) {
		t.Fatalf("fixture did not dispatch an over-original-budget prediction: %+v", got)
	}
	if got.ceilingMS != 0 || got.wireMS <= 0 || got.wireMS > int64(got.originalMS) || got.absoluteExpiry.IsZero() {
		t.Fatalf("soft prediction gate must be off while absolute/wire budget stays on: %+v", got)
	}
	t.Logf("provider=%s predicted_ms=%.3f original_budget_ms=%d max_ttft_ms=%.3f wire_budget_ms=%d",
		got.provider, got.predictedMS, got.originalMS, got.ceilingMS, got.wireMS)
}

func TestSoftPredictiveAdmissionDeadlineRefusalKeepsOriginalClock(t *testing.T) {
	t.Setenv(envProfiler, "on")
	reg, memory, _, ts := setupTTFTFailoverServer(t) // Default soft prediction gate.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	const model = "soft-refusal-original-clock"
	observations := make(chan predictiveAdmissionObservation, 2)
	var attempts deadlineAttemptRecorder
	script := func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
		observations <- observePredictiveAdmission(t, reg, fp, req)
		if attempts.capture(t, reg, fp, req) == 1 {
			// Spend real request time before the typed refusal; the retry may
			// not restore that time, even though the predictive gate is off.
			time.Sleep(100 * time.Millisecond)
			fp.sendTypedInferenceError(ctx, req, protocol.FailureCodeCapacity,
				failure.ErrorReasonDeadlineUnreachable, http.StatusServiceUnavailable)
			return
		}
		fp.serveFull(ctx, req, model, "retry-success")
	}
	for i := 0; i < 2; i++ {
		p := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
			Name: fmt.Sprintf("slow-provider-%d", i), Version: "0.8.16", DecodeTPS: 100,
			Models: []failoverModelSpec{{ID: model}}, Script: script,
		})
		makeProviderTTFTSlow(t, reg, p.registryID, model)
	}
	status, response, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatal(err)
	}
	if status != http.StatusOK || !strings.Contains(response, "retry-success") || len(attempts.snapshot()) != 2 {
		t.Fatalf("status=%d attempts=%+v body=%s", status, attempts.snapshot(), response)
	}
	first, second := <-observations, <-observations
	assertSoftOverBudgetDispatch(t, first)
	assertSoftOverBudgetDispatch(t, second)
	if first.provider == second.provider || !first.absoluteExpiry.Equal(second.absoluteExpiry) || first.originalMS != second.originalMS {
		t.Fatalf("retry must change provider while keeping one request clock: first=%+v second=%+v", first, second)
	}
	if second.wireMS >= first.wireMS || first.wireMS-second.wireMS < 50 {
		t.Fatalf("retry restored time spent before refusal: first=%+v second=%+v", first, second)
	}
	// Both the refusal and winner must retain their own writer budget after
	// passing through the asynchronous profile sink into storage.
	want := map[string]int64{first.requestID: first.wireMS, second.requestID: second.wireMS}
	until := time.Now().Add(3 * time.Second)
	for len(want) > 0 && time.Now().Before(until) {
		for _, rec := range memory.RequestProfilesSinceFiltered(time.Time{}, store.RequestProfileFilter{}) {
			budget, ok := want[rec.RequestID]
			if !ok {
				continue
			}
			if rec.AdmissionMode != "soft" || rec.PredictiveBypass != "none" || rec.DispatchBudgetMs == nil || *rec.DispatchBudgetMs != budget || rec.ReservationTTFTCeilingMs == nil || *rec.ReservationTTFTCeilingMs != 0 {
				t.Fatalf("stored attempt lost decision evidence: %+v", rec)
			}
			delete(want, rec.RequestID)
		}
		if len(want) > 0 {
			time.Sleep(10 * time.Millisecond)
		}
	}
	if len(want) > 0 {
		t.Fatalf("missing persisted attempt observations: %v", want)
	}

}
