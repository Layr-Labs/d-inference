package api

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestFastCompletionStampsActualTTFT is the regression for the FirstContentAt
// stamp-ordering bug (Codex P2, dispatch.go ~2301): a fast single-chunk
// completion can have its TypeInferenceComplete reach handleComplete BEFORE the
// dispatch goroutine stamps FirstContentAt. Since applyPendingRouteTelemetry now
// derives actual_ttft_ms SOLELY from FirstContentAt, the terminal
// completeRouteOutcome would then persist actual_ttft_ms as 0/NULL even though
// tokens were delivered.
//
// This drives handleComplete with FirstContentAt deliberately unstamped (the
// race) and a positive completion-token count. handleComplete's fallback stamps
// FirstContentAt because the provider reported delivered tokens, so the persisted
// actual_ttft_ms is > 0. Without the fix this test fails (ActualTTFTMs == 0).
func TestFastCompletionStampsActualTTFT(t *testing.T) {
	srv, st, _ := billingTestServer(t)

	model := "fast-ttft-model"
	provider := srv.registry.Register("fast-ttft-provider", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})

	// Committed attempt whose dispatch happened 50ms ago, but whose first content
	// chunk the dispatch goroutine has NOT yet stamped (FirstContentAt zero) —
	// exactly the fast-completion race the fix closes.
	pr := &registry.PendingRequest{
		RequestID:        "fast-ttft-req",
		Model:            model,
		ConsumerKey:      testConsumerID,
		ReservedMicroUSD: 10_000_000,
		ChunkCh:          make(chan string, 1),
		CompleteCh:       make(chan protocol.UsageInfo, 1),
		ErrorCh:          make(chan protocol.InferenceErrorMessage, 1),
		Timing: &registry.RequestTiming{
			ReceivedAt:   time.Now().Add(-60 * time.Millisecond),
			DispatchedAt: time.Now().Add(-50 * time.Millisecond),
			// FirstChunkAt / FirstContentAt intentionally unset (zero).
		},
	}
	provider.AddPending(pr)

	// Pre-create the route row so the (best-effort, async) outcome update lands.
	if err := st.RecordInferenceRoute(&store.InferenceRouteRecord{
		RequestID:  pr.RequestID,
		Attempt:    pr.Attempt,
		Model:      model,
		ProviderID: provider.ID,
	}); err != nil {
		t.Fatalf("record route: %v", err)
	}

	srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: pr.RequestID,
		Usage:     protocol.UsageInfo{PromptTokens: 1000, CompletionTokens: 1},
	})

	// The outcome write is best-effort async (telemetry sink), so poll for it.
	deadline := time.Now().Add(2 * time.Second)
	var rec *store.InferenceRouteRecord
	for time.Now().Before(deadline) {
		if rec = findRouteRecord(st, pr.RequestID); rec != nil && rec.FinalStatus != "" {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if rec == nil || rec.FinalStatus == "" {
		t.Fatal("route record not found / not finalized")
	}
	if rec.FinalStatus != "success" {
		t.Fatalf("final_status = %q, want success", rec.FinalStatus)
	}
	if rec.ActualTTFTMs <= 0 {
		t.Fatalf("actual_ttft_ms must be populated and > 0 for a delivered completion, got %f (0/NULL = the FirstContentAt stamp-ordering bug)", rec.ActualTTFTMs)
	}
}
