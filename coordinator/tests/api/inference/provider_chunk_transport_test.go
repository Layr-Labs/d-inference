package inference_test

import (
	"encoding/base64"
	"log/slog"
	"net/http"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestHandleChunkDecryptsEncryptedTextChunk(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := newComposedServer(reg, st, TestServerConfig{}, logger)
	t.Cleanup(srv.Close)

	providerPublicKey := testPublicKeyB64()
	provider := reg.Register("provider-1", nil, &protocol.RegisterMessage{
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
		RequestID:      "req-1",
		Model:          "test-model",
		ChunkCh:        make(chan registry.ProviderChunk, 1),
		CompleteCh:     make(chan protocol.UsageInfo, 1),
		ErrorCh:        make(chan protocol.InferenceErrorMessage, 1),
		SessionPrivKey: &sessionKeys.PrivateKey,
	}
	provider.AddPending(pr)

	expected := `data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"secret"}}]}`
	chunk := testEncryptedChunk(t, protocol.InferenceRequestMessage{
		RequestID: "req-1",
		EncryptedBody: &protocol.EncryptedPayload{
			EphemeralPublicKey: base64.StdEncoding.EncodeToString(sessionKeys.PublicKey[:]),
			Ciphertext:         "",
		},
	}, providerPublicKey, expected)

	srv.HandleChunk(provider.ID, provider, &chunk)

	select {
	case got := <-pr.ChunkCh:
		if got.Data != expected {
			t.Fatalf("chunk = %q, want %q", got.Data, expected)
		}
		if got.ReceivedAt.IsZero() {
			t.Fatal("provider chunk is missing ingress timestamp")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for decrypted chunk")
	}

	select {
	case errMsg := <-pr.ErrorCh:
		t.Fatalf("unexpected error: %+v", errMsg)
	default:
	}
}

func TestHandleChunkRejectsPlaintextTextChunk(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := newComposedServer(reg, st, TestServerConfig{}, logger)
	t.Cleanup(srv.Close)

	providerPublicKey := testPublicKeyB64()
	provider := reg.Register("provider-1", nil, &protocol.RegisterMessage{
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
		RequestID:      "req-plain",
		Model:          "test-model",
		ChunkCh:        make(chan registry.ProviderChunk, 1),
		CompleteCh:     make(chan protocol.UsageInfo, 1),
		ErrorCh:        make(chan protocol.InferenceErrorMessage, 1),
		SessionPrivKey: &sessionKeys.PrivateKey,
	}
	provider.AddPending(pr)

	srv.HandleChunk(provider.ID, provider, &protocol.InferenceResponseChunkMessage{
		Type:      protocol.TypeInferenceResponseChunk,
		RequestID: pr.RequestID,
		Data:      `data: {"plaintext":true}`,
	})

	select {
	case errMsg, ok := <-pr.ErrorCh:
		if !ok {
			t.Fatal("error channel closed before error was delivered")
		}
		if errMsg.StatusCode != http.StatusBadGateway {
			t.Fatalf("status code = %d, want %d", errMsg.StatusCode, http.StatusBadGateway)
		}
		if errMsg.Error != "encrypted inference transport failed" {
			t.Fatalf("error = %q", errMsg.Error)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for plaintext chunk rejection")
	}

	if got := reg.GetProvider(provider.ID); got == nil || got.Status != registry.StatusUntrusted {
		t.Fatalf("provider status = %v, want %v", got.Status, registry.StatusUntrusted)
	}

	if provider.GetPending(pr.RequestID) != nil {
		t.Fatal("pending request still registered after plaintext chunk violation")
	}

	select {
	case chunk, ok := <-pr.ChunkCh:
		if ok {
			t.Fatalf("unexpected chunk delivered: %q", chunk)
		}
	default:
		t.Fatal("chunk channel should be closed after plaintext chunk violation")
	}
}

func TestHandleChunkRejectsMixedPlaintextAndEncryptedTextChunk(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := newComposedServer(reg, st, TestServerConfig{}, logger)
	t.Cleanup(srv.Close)

	providerPublicKey := testPublicKeyB64()
	provider := reg.Register("provider-mixed", nil, &protocol.RegisterMessage{
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
		RequestID:      "req-mixed",
		Model:          "test-model",
		ChunkCh:        make(chan registry.ProviderChunk, 1),
		CompleteCh:     make(chan protocol.UsageInfo, 1),
		ErrorCh:        make(chan protocol.InferenceErrorMessage, 1),
		SessionPrivKey: &sessionKeys.PrivateKey,
	}
	provider.AddPending(pr)

	expected := `data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"secret"}}]}`
	chunk := testEncryptedChunk(t, protocol.InferenceRequestMessage{
		RequestID: "req-mixed",
		EncryptedBody: &protocol.EncryptedPayload{
			EphemeralPublicKey: base64.StdEncoding.EncodeToString(sessionKeys.PublicKey[:]),
			Ciphertext:         "",
		},
	}, providerPublicKey, expected)
	chunk.Data = `data: {"plaintext":"leak"}`

	srv.HandleChunk(provider.ID, provider, &chunk)

	select {
	case errMsg := <-pr.ErrorCh:
		if errMsg.StatusCode != http.StatusBadGateway {
			t.Fatalf("status code = %d, want %d", errMsg.StatusCode, http.StatusBadGateway)
		}
		if errMsg.Error != "encrypted inference transport failed" {
			t.Fatalf("error = %q", errMsg.Error)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for mixed chunk rejection")
	}

	if got := reg.GetProvider(provider.ID); got == nil || got.Status != registry.StatusUntrusted {
		t.Fatalf("provider status = %v, want %v", got.Status, registry.StatusUntrusted)
	}
}
