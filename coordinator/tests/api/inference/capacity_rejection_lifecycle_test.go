package inference_test

import (
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// After-commit client-gone regression: a stream that commits before the pair's
// first windowed reject records its accept immediately. If the consumer then
// disconnects and the provider completes into the parked settlement path,
// handleComplete must observe the commit-time stamp and avoid counting it again.
func TestCapacityRateParkedCompletionCountsAtHandleComplete(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := newComposedServer(reg, st, TestServerConfig{}, logger)

	const model = "gemma-4-26b-8bit"
	p := makeRoutableProvider(t, reg, "p-parked", model)

	pr := capacityTestPending(model, p.ID, 1)
	pr.ConsumerKey = "test-key"

	// Commit first content while the pair is healthy (no reject in-window yet),
	// mirroring commitFirstContent and its request-local exactly-once stamp.
	if !reg.RecordCapacityAccept(pr.ProviderID, model) {
		t.Fatal("commit-time accept must be retained before the first reject")
	}
	pr.MarkRateOutcomeCounted()

	// The pair goes gray while the (now client-gone) stream is still serving.
	reg.RecordCapacityReject(pr.ProviderID, model)
	if _, samples := reg.CapacityRejectRate(pr.ProviderID, model); samples != 2 {
		t.Fatalf("setup: samples=%d after one accept and one reject, want 2", samples)
	}

	// Consumer disconnected mid-stream: the request is parked (no reader), then
	// the provider completes. handleComplete claims the parked record
	// (consumerGone=true) and must not re-offer the already recorded accept.
	srv.late.Hold(pr)
	srv.HandleCompleteAt(p.ID, p, &protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: pr.RequestID,
		Usage:     protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 200},
	}, time.Now(),
	)

	rate, samples := reg.CapacityRejectRate(pr.ProviderID, model)
	if samples != 2 {
		t.Fatalf("samples=%d after parked completion, want 2 — completion double-counted the commit", samples)
	}
	if rate != 0.5 {
		t.Fatalf("rate=%.2f, want 0.5 (1 reject / 2 outcomes)", rate)
	}
}
