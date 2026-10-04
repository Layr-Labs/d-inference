package inference_test

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
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

// This is a local protocol experiment, not a throughput benchmark: the real
// HTTP handlers, registry, encryption, and WebSocket writer select a provider
// advertising a slow rate, while its scripted response is immediate. It
// distinguishes a disabled predictive gate from a missing absolute deadline.
func TestPredictiveAdmissionOverOriginalBudgetHTTP(t *testing.T) {
	t.Setenv(envProfiler, "on")
	for _, endpoint := range []string{"/v1/chat/completions", "/v1/completions"} {
		for _, hard := range []bool{false, true} {
			name := fmt.Sprintf("%s/hard=%t", strings.TrimPrefix(endpoint, "/v1/"), hard)
			t.Run(name, func(t *testing.T) {
				reg, _, srv, ts := setupTTFTFailoverServer(t)
				srv.SetTTFTHardReject(hard)
				ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
				defer cancel()
				model := "predictive-policy-" + strings.ReplaceAll(name, "/", "-")
				observations := make(chan predictiveAdmissionObservation, 1)
				provider := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
					Name: "slow-advertised-provider", Version: "0.8.16", DecodeTPS: 100,
					Models: []failoverModelSpec{{ID: model}},
					Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
						observations <- observePredictiveAdmission(t, reg, fp, req)
						fp.serveFull(ctx, req, model, "policy-success")
					},
				})
				makeProviderTTFTSlow(t, reg, provider.registryID, model)
				body := buildChatBody(t, model, true, nil)
				if endpoint == "/v1/completions" {
					body = fmt.Sprintf(`{"model":%q,"prompt":"hello","max_tokens":16}`, model)
				}
				status, response, err := postGenericInference(ctx, ts.URL, endpoint, body)
				if err != nil {
					t.Fatal(err)
				}
				if hard {
					if status != http.StatusTooManyRequests || !strings.Contains(response, "TTFT target") || provider.dispatches.Load() != 0 {
						t.Fatalf("hard gate: status=%d sends=%d body=%s", status, provider.dispatches.Load(), response)
					}
					t.Logf("hard gate: HTTP %d, actual inference sends=0", status)
					return
				}
				if status != http.StatusOK || !strings.Contains(response, "policy-success") || provider.dispatches.Load() != 1 {
					t.Fatalf("soft gate: status=%d sends=%d body=%s", status, provider.dispatches.Load(), response)
				}
				assertSoftOverBudgetDispatch(t, <-observations)
			})
		}
	}
}
