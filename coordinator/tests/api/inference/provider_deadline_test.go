package inference_test

import (
	"encoding/base64"
	"io"
	"log/slog"
	"net/http"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	failure "github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestHandleChunkRejectsFirstContentReceivedAfterDeadline(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	srv := newComposedServer(reg, memory.NewMemory(store.Config{AdminKey: "test-key"}), TestServerConfig{}, logger)

	providerPublicKey := testPublicKeyB64()
	provider := reg.Register("provider-late", nil, &protocol.RegisterMessage{
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
		RequestID:            "req-late",
		Model:                "test-model",
		FirstContentDeadline: time.Now().Add(-time.Millisecond),
		ChunkCh:              make(chan registry.ProviderChunk, 1),
		CompleteCh:           make(chan protocol.UsageInfo, 1),
		ErrorCh:              make(chan protocol.InferenceErrorMessage, 1),
		SessionPrivKey:       &sessionKeys.PrivateKey,
	}
	provider.AddPending(pr)
	chunk := testEncryptedChunk(t, protocol.InferenceRequestMessage{
		RequestID: pr.RequestID,
		EncryptedBody: &protocol.EncryptedPayload{
			EphemeralPublicKey: base64.StdEncoding.EncodeToString(sessionKeys.PublicKey[:]),
		},
	}, providerPublicKey, `data: {"choices":[{"delta":{"content":"late"}}]}`)

	srv.HandleChunk(provider.ID, provider, &chunk)

	errMsg, ok := <-pr.ErrorCh
	if !ok {
		t.Fatal("error channel closed before deadline error was delivered")
	}
	if errMsg.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("status code = %d, want %d", errMsg.StatusCode, http.StatusServiceUnavailable)
	}
	if errMsg.ErrorReason != failure.ErrorReasonDeadlineUnreachable {
		t.Fatalf("error reason = %q, want %q", errMsg.ErrorReason, failure.ErrorReasonDeadlineUnreachable)
	}
	if _, ok := <-pr.ChunkCh; ok {
		t.Fatal("late first content was delivered")
	}
	if provider.GetPending(pr.RequestID) != nil {
		t.Fatal("pending request survived late first-content rejection")
	}
}

func TestHandleCompleteRejectsNoContentAfterDeadline(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	srv := newComposedServer(reg, memory.NewMemory(store.Config{AdminKey: "test-key"}), TestServerConfig{}, logger)
	provider := reg.Register("provider-late-complete", nil, &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:  "mlx-swift",
	})
	pr := &registry.PendingRequest{
		RequestID:            "req-late-complete",
		Model:                "test-model",
		FirstContentDeadline: time.Now().Add(-time.Millisecond),
		ChunkCh:              make(chan registry.ProviderChunk, 1),
		CompleteCh:           make(chan protocol.UsageInfo, 1),
		ErrorCh:              make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)

	srv.HandleCompleteAt(provider.ID, provider, &protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: pr.RequestID,
	}, time.Now(),
	)

	errMsg, ok := <-pr.ErrorCh
	if !ok {
		t.Fatal("error channel closed before completion deadline error was delivered")
	}
	if errMsg.ErrorReason != failure.ErrorReasonDeadlineUnreachable {
		t.Fatalf("error reason = %q, want %q", errMsg.ErrorReason, failure.ErrorReasonDeadlineUnreachable)
	}
	if _, ok := <-pr.ChunkCh; ok {
		t.Fatal("late no-content completion opened the response")
	}
	if provider.GetPending(pr.RequestID) != nil {
		t.Fatal("pending request survived late no-content completion")
	}
}
