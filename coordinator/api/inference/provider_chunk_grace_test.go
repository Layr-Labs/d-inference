package inference

import (
	"encoding/base64"
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// TestHandleChunkOverflowGraceDeliversToSlowConsumer pins the bounded-grace
// half of the overflow behavior: a consumer that is merely bursty — full
// buffer at arrival time but draining within chunkOverflowGrace — must get the
// chunk delivered and keep its stream alive, NOT be killed with a 499.
func TestHandleChunkOverflowGraceDeliversToSlowConsumer(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := newComposedServer(reg, st, TestServerConfig{}, logger)
	t.Cleanup(srv.Close)

	providerPublicKey := testPublicKeyB64()
	provider := reg.Register("provider-grace", nil, &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
		PublicKey:               providerPublicKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	})

	sessionKeys, err := e2e.GenerateSessionKeys()
	if err != nil {
		t.Fatalf("generate session keys: %v", err)
	}

	pr := &registry.PendingRequest{
		RequestID:      "req-grace",
		Model:          "test-model",
		ChunkCh:        make(chan registry.ProviderChunk, 1),
		CompleteCh:     make(chan protocol.UsageInfo, 1),
		ErrorCh:        make(chan protocol.InferenceErrorMessage, 1),
		SessionPrivKey: &sessionKeys.PrivateKey,
	}
	pr.ChunkCh <- registry.ProviderChunk{Data: "data: buffered-but-draining"}
	provider.AddPending(pr)

	// Simulate a slow-but-alive consumer: drain one slot well within the
	// grace window while handleChunk is blocked in sendChunkWithGrace.
	drained := make(chan registry.ProviderChunk, 1)
	go func() {
		time.Sleep(30 * time.Millisecond)
		drained <- <-pr.ChunkCh
	}()

	chunk := testEncryptedChunk(t, protocol.InferenceRequestMessage{
		RequestID: pr.RequestID,
		EncryptedBody: &protocol.EncryptedPayload{
			EphemeralPublicKey: base64.StdEncoding.EncodeToString(sessionKeys.PublicKey[:]),
			Ciphertext:         "",
		},
	}, providerPublicKey, `data: {"choices":[{"delta":{"content":"late-but-delivered"}}]}`)

	srv.HandleChunk(provider.ID, provider, &chunk)

	select {
	case first := <-drained:
		if first.Data != "data: buffered-but-draining" {
			t.Fatalf("drained chunk = %q, want the pre-filled one", first.Data)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for the drainer")
	}

	// The overflowing chunk must have been delivered into the freed slot.
	select {
	case got := <-pr.ChunkCh:
		if got.Data == "" {
			t.Fatal("empty chunk delivered")
		}
		if got.ReceivedAt.IsZero() {
			t.Fatal("overflow-grace chunk is missing ingress timestamp")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("overflowing chunk was not delivered despite the consumer draining within grace")
	}

	// No terminal: the request survives.
	select {
	case errMsg := <-pr.ErrorCh:
		t.Fatalf("unexpected terminal error %+v; grace delivery must not abort the request", errMsg)
	default:
	}
	if provider.GetPending(pr.RequestID) == nil {
		t.Fatal("pending request was removed; grace delivery must keep the stream alive")
	}
}
