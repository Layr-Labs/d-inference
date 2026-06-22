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
// This drives handleComplete for the COMMITTED attempt (MarkContentCommitted set,
// as commitFirstContent does in the dispatch path) with FirstContentAt
// deliberately unstamped (the race) and a positive completion-token count.
// handleComplete's committed-attempt fallback stamps FirstContentAt, so the
// persisted actual_ttft_ms is > 0. Without the fix this test fails
// (ActualTTFTMs == 0).
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
	// This IS the committed attempt (the dispatch path marks it via
	// commitFirstContent); the fallback is scoped to committed attempts.
	pr.MarkContentCommitted()
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

// TestAbandonedAttemptDoesNotStampCommittedTTFT is the regression for the
// committed-attempt fallback guard (Codex P2 round 3): an abandoned/retried
// attempt that completes LATE (the provider finished after the coordinator timed
// it out and retried) must NOT stamp FirstContentAt on the Timing it SHARES with
// the committed retry. FirstContentAt is first-write-wins, so a stale stamp from
// the abandoned attempt would clamp/zero the committed retry's actual_ttft_ms.
// The fallback is gated on ContentCommittedSafe, and the abandoned attempt was
// never committed, so it must leave FirstContentAt untouched — letting the
// committed retry's first-content time win.
func TestAbandonedAttemptDoesNotStampCommittedTTFT(t *testing.T) {
	srv, st, _ := billingTestServer(t)

	model := "abandoned-ttft-model"
	provider := srv.registry.Register("abandoned-ttft-provider", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})

	// Timing is SHARED across attempts (dispatch.go sets Timing: d.timing on every
	// attempt). DispatchedAt reflects the committed retry's dispatch.
	shared := &registry.RequestTiming{
		ReceivedAt:   time.Now().Add(-time.Second),
		DispatchedAt: time.Now().Add(-200 * time.Millisecond),
		// FirstContentAt unset: the committed retry has not delivered content yet.
	}
	// The abandoned attempt (attempt 0) — never committed (no MarkContentCommitted).
	abandoned := &registry.PendingRequest{
		RequestID:        "abandoned-attempt",
		Attempt:          0,
		Model:            model,
		ConsumerKey:      testConsumerID,
		ReservedMicroUSD: 10_000_000,
		ChunkCh:          make(chan string, 1),
		CompleteCh:       make(chan protocol.UsageInfo, 1),
		ErrorCh:          make(chan protocol.InferenceErrorMessage, 1),
		Timing:           shared,
	}
	provider.AddPending(abandoned)
	if err := st.RecordInferenceRoute(&store.InferenceRouteRecord{
		RequestID: abandoned.RequestID, Attempt: abandoned.Attempt, Model: model, ProviderID: provider.ID,
	}); err != nil {
		t.Fatalf("record route: %v", err)
	}

	// The abandoned attempt completes late, with delivered tokens. The fallback
	// must NOT stamp the shared FirstContentAt (it was never the committed attempt).
	srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: abandoned.RequestID,
		Usage:     protocol.UsageInfo{PromptTokens: 1000, CompletionTokens: 5},
	})

	if !shared.FirstContentAt.IsZero() {
		t.Fatalf("abandoned attempt must NOT stamp the shared FirstContentAt, got %v (would clamp the committed retry's actual_ttft_ms)", shared.FirstContentAt)
	}

	// The committed retry then delivers its first content — its stamp wins, and
	// its actual_ttft_ms is measured from the shared DispatchedAt (positive).
	committed := &registry.PendingRequest{RequestID: "committed-retry", Attempt: 1, Model: model, Timing: shared}
	committed.MarkContentCommitted()
	committed.MarkFirstContentArrived()
	if shared.FirstContentAt.IsZero() {
		t.Fatal("committed retry's first-content stamp must win")
	}
	out := completeRouteOutcome(committed, protocol.UsageInfo{PromptTokens: 1000, CompletionTokens: 5}, 0, false)
	if out.ActualTTFTMs <= 0 {
		t.Fatalf("committed retry actual_ttft_ms must be > 0 (its own first-content time), got %f", out.ActualTTFTMs)
	}
	if out.InvalidTTFT {
		t.Fatal("committed retry actual_ttft_ms must be a clean positive, not the negative-clamp guard")
	}
}
