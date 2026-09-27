package api

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// A short pending prompt must not be priced as another copy of a long arrival.
// The single provider completes through the real HTTP/encrypted WebSocket path;
// its output is scripted, so this is not a provider throughput measurement.
func TestTTFTPendingPromptHTTPSingleProviderCompletesLongArrival(t *testing.T) {
	registry.ResetTTFTCalibration()
	t.Cleanup(registry.ResetTTFTCalibration)
	reg, _, srv, ts := setupTTFTFailoverServerWithConfig(t, ServerConfig{FirstContentDeadlineBase: 5 * time.Second})
	t.Cleanup(srv.Close)
	srv.SetTTFTHardReject(true)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	const model = "pending-short-long-http"
	const marker = "long arrival completed"
	var budgets deadlineAttemptRecorder
	fp := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "only-provider", Version: "0.8.10", DecodeTPS: 100,
		Models: []failoverModelSpec{{ID: model}},
		Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
			budgets.capture(t, reg, fp, req)
			fp.serveFull(ctx, req, model, marker)
		},
	})
	p := reg.GetProvider(fp.registryID)
	p.Mu().Lock()
	p.PrefillTPS = 250
	p.Mu().Unlock()
	reg.Heartbeat(fp.registryID, &protocol.HeartbeatMessage{
		Status: "idle", BackendCapacity: &protocol.BackendCapacity{
			TotalMemoryGB: 64,
			Slots:         []protocol.BackendSlotCapacity{{Model: model, State: "running", MaxConcurrency: 8, ActiveTokenBudgetMax: 100_000}},
		},
	})
	p.AddPending(&registry.PendingRequest{RequestID: "short-ahead", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 128})
	defer p.RemovePending("short-ahead")
	body, err := json.Marshal(map[string]any{
		"model": model, "messages": []map[string]any{{"role": "user", "content": strings.Repeat("a", 4_000)}},
		"stream": true, "max_tokens": 64,
	})
	if err != nil {
		t.Fatal(err)
	}
	status, response, err := postChat(ctx, ts.URL, "test-key", string(body))
	if err != nil {
		t.Fatal(err)
	}
	assertCleanFailoverStream(t, status, response, marker)
	if got := fp.dispatchCount(); got != 1 {
		t.Fatalf("provider dispatches=%d, want one completed attempt", got)
	}
	got := budgets.snapshot()
	if len(got) != 1 || got[0].wireMS <= 0 || got[0].maxTTFTMS <= 0 {
		t.Fatalf("original request budget missing from single-provider dispatch: %+v", got)
	}
}

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
