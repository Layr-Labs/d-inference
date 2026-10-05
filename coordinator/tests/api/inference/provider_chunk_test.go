package inference_test

import (
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestHandleCompleteDefersSpeculativeEmptySettlementToDispatchOwner(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	srv := newComposedServer(reg, memory.NewMemory(store.Config{AdminKey: "test-key"}), TestServerConfig{}, logger)
	provider := reg.Register("provider-speculative-loser", nil, &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:  "mlx-swift",
	})
	pr := &registry.PendingRequest{
		RequestID:            "req-speculative-loser",
		Model:                "test-model",
		FirstContentDeadline: time.Now().Add(time.Minute),
		ChunkCh:              make(chan registry.ProviderChunk, 1),
		CompleteCh:           make(chan protocol.UsageInfo, 1),
		ErrorCh:              make(chan protocol.InferenceErrorMessage, 1),
	}
	pr.EnableSpeculativeEmptyCompletionArbitration()
	provider.AddPending(pr)

	done := make(chan struct{})
	go func() {
		srv.HandleCompleteAt(provider.ID, provider, &protocol.InferenceCompleteMessage{
			Type:      protocol.TypeInferenceComplete,
			RequestID: pr.RequestID,
		}, time.Now())
		close(done)
	}()
	<-pr.CompletionIngressSignal()
	select {
	case <-done:
		t.Fatal("empty completion settled before speculative arbitration")
	default:
	}

	firstcontent.ReleaseUnsent(srv.registry, provider, pr)
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("rejected empty completion did not release provider read handler")
	}
	if provider.GetPending(pr.RequestID) != nil {
		t.Fatal("failed dispatch cleanup left pending state behind")
	}
	select {
	case <-pr.CompleteCh:
		t.Fatal("losing completion was published to the consumer")
	default:
	}
}
