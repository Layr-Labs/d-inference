package api

import (
	"context"
	"encoding/json"
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
