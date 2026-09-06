package api

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// The coordinator and provider protocol are real; provider compute/refusal is
// scripted. This proves the input correction preserves a completed HTTP
// response through the feasible alternative, not real MLX service-time accuracy.
func TestTTFTPendingPromptHTTPSelectsFeasibleAlternative(t *testing.T) {
	registry.ResetTTFTCalibration()
	t.Cleanup(registry.ResetTTFTCalibration)
	reg, _, srv, ts := setupTTFTFailoverServer(t)
	srv.SetTTFTHardReject(true)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	const model = "pending-prompt-http"
	var budgets deadlineAttemptRecorder
	busy := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "busy", Version: "0.8.10", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}},
		Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
			budgets.capture(t, reg, fp, req)
			fp.sendTypedInferenceError(ctx, req, protocol.FailureCodeCapacity, errorReasonDeadlineUnreachable, http.StatusServiceUnavailable)
		},
	})
	idle := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "idle", Version: "0.8.10", DecodeTPS: 1,
		Models: []failoverModelSpec{{ID: model}},
		Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
			budgets.capture(t, reg, fp, req)
			fp.serveFull(ctx, req, model, markerFor(fp.name))
		},
	})
	for _, fp := range []*failoverProvider{busy, idle} {
		p := reg.GetProvider(fp.registryID)
		p.Mu().Lock()
		p.PrefillTPS = 1000
		p.BackendCapacity = &protocol.BackendCapacity{
			TotalMemoryGB: 64,
			Slots:         []protocol.BackendSlotCapacity{{Model: model, State: "running", ActiveTokenBudgetMax: 200_000}},
		}
		p.Mu().Unlock()
	}
	p := reg.GetProvider(busy.registryID)
	p.AddPending(&registry.PendingRequest{RequestID: "long-ahead", Model: model, EstimatedPromptTokens: 20_000, RequestedMaxTokens: 1})
	defer p.RemovePending("long-ahead")
	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatal(err)
	}
	assertCleanFailoverStream(t, status, body, markerFor(idle.name))
	t.Logf("synthetic incoming_requests=1 dispatched_attempts=%d scripted_refusals=%d timely_first_content=1 completed_http_responses=1 client_departures=0 interrupted_responses=0 provider_compute=scripted", busy.dispatchCount()+idle.dispatchCount(), busy.dispatchCount())
	if busy.dispatchCount() != 0 || idle.dispatchCount() != 1 {
		t.Fatalf("dispatches busy=%d idle=%d, want 0/1 while preserving HTTP completion", busy.dispatchCount(), idle.dispatchCount())
	}
	got := budgets.snapshot()
	if len(got) != 1 || got[0].wireMS <= 0 || got[0].maxTTFTMS <= 0 {
		t.Fatalf("original request budget missing from selected alternative: %+v", got)
	}
}
