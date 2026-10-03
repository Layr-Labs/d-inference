package inference

import (
	"io"
	"log/slog"
	"net/http"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// TestHandleInferenceErrorReputationCarveout verifies that capacity rejections
// (HTTP 503/429, token-budget exhaustion, out-of-memory load rejects) do NOT
// count against a provider's reputation, while a genuine provider fault (HTTP
// 500) still records a job failure. It drives handleInferenceError directly so
// the carve-out is asserted deterministically without the HTTP/WebSocket flow.
// A registry without a store keeps reputation reads race-free (no async
// persistence goroutine).
func TestHandleInferenceErrorReputationCarveout(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError}))
	reg := registry.New(logger)
	srv := newComposedServer(reg, memory.NewMemory(store.Config{}), TestServerConfig{}, logger)
	t.Cleanup(srv.Close)
	reg.SetStore(nil)

	regMsg := &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: "cap-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:  "mlx-swift",
	}
	p := reg.Register("prov-reputation", nil, regMsg)
	if p == nil {
		t.Fatal("Register returned nil provider")
	}

	// deliverError registers a fresh pending request and routes a single
	// inference error through handleInferenceError. Channels are buffered so
	// the synchronous delivery never blocks.
	deliverError := func(requestID, errText string, status int, failureCode protocol.InferenceFailureCode) {
		pr := &registry.PendingRequest{
			RequestID:  requestID,
			ProviderID: p.ID,
			Model:      "cap-model",
			ChunkCh:    make(chan registry.ProviderChunk, 1),
			CompleteCh: make(chan protocol.UsageInfo, 1),
			ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
		}
		p.AddPending(pr)
		srv.HandleInferenceError(p.ID, p, &protocol.InferenceErrorMessage{
			Type:        protocol.TypeInferenceError,
			RequestID:   requestID,
			Error:       errText,
			StatusCode:  status,
			FailureCode: failureCode,
		})
	}

	// Capacity rejections must NOT be penalised:
	//   - 503 service unavailable (e.g. provider pre-accept reject)
	//   - 429 too many requests
	//   - token_budget_exhausted (carried in the error message, status 200)
	//   - "insufficient memory" message even on a 500 (case-insensitive)
	deliverError("req-503", "insufficient memory to load model 'cap-model'", http.StatusServiceUnavailable, protocol.FailureCodeCapacity)
	deliverError("req-429", "rate limited", http.StatusTooManyRequests, protocol.FailureCodeCapacity)
	deliverError("req-budget", "token_budget_exhausted", http.StatusOK, protocol.FailureCodeCapacity)
	deliverError("req-oom-500", "Insufficient memory (78.9 GB free, need 93.7 GB)", http.StatusInternalServerError, protocol.FailureCodeCapacity)

	if got := p.Reputation.FailedJobs; got != 0 {
		t.Fatalf("after capacity rejections: FailedJobs = %d, want 0 (no reputation penalty)", got)
	}
	if got := p.Reputation.TotalJobs; got != 0 {
		t.Fatalf("after capacity rejections: TotalJobs = %d, want 0", got)
	}

	// A genuine provider fault (500, no capacity keywords) still penalises.
	deliverError("req-fault-500", "model crashed during generation", http.StatusInternalServerError, protocol.FailureCodeGenerationFailure)

	if got := p.Reputation.FailedJobs; got != 1 {
		t.Fatalf("after genuine fault: FailedJobs = %d, want 1", got)
	}
	if got := p.Reputation.TotalJobs; got != 1 {
		t.Fatalf("after genuine fault: TotalJobs = %d, want 1", got)
	}
}
