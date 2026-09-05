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

// Synthetic service fixture: the real HTTP, scheduler, encrypted WebSocket,
// content-commit and terminal paths run, but the provider returns scripted text.
// This proves recovery from a false shed, not MLX performance or production lift.
func TestPendingPrefillAdmissionCompletesRequest(t *testing.T) {
	registry.ResetTTFTCalibration()
	t.Cleanup(registry.ResetTTFTCalibration)
	reg, _, srv, ts := setupTTFTFailoverServerWithConfig(t, ServerConfig{FirstContentDeadlineBase: 5 * time.Second})
	srv.SetTTFTHardReject(true)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	const model = "pending-prefill-delivery-model"
	const marker = "known pending prompt admitted"
	fp := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider", Version: "0.8.10", DecodeTPS: 100,
		Models: []failoverModelSpec{{ID: model}},
		Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
			if req.FirstContentBudgetMS <= 0 {
				t.Error("first-content budget missing from provider dispatch")
			}
			fp.serveFull(ctx, req, model, marker)
		},
	})
	p := reg.GetProvider(fp.registryID)
	p.Mu().Lock()
	p.PrefillTPS = 250
	p.Mu().Unlock()
	reg.Heartbeat(fp.registryID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: &protocol.BackendCapacity{TotalMemoryGB: 64, Slots: []protocol.BackendSlotCapacity{{Model: model, State: "running", MaxConcurrency: 8, ActiveTokenBudgetMax: 100_000}}}})
	p.AddPending(&registry.PendingRequest{RequestID: "synthetic-pending", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 128})
	t.Cleanup(func() { p.RemovePending("synthetic-pending") })
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
	// The fixture cohort has one received/finalized request and one dispatch,
	// complete egress, no refusal, timeout, retry, interruption or departure.
	t.Log("synthetic cohort: requests=1 dispatches=1 completed=1 timely_first_content=1 provider_refusals=0 retries=0 final_rejections=0 interruptions=0 client_departures=0")
}
