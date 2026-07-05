package api

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
)

// TestHandleChunkOverflowFailsRequest pins the chunk-buffer-overflow behavior:
// when a valid encrypted chunk arrives but the consumer's ChunkCh is full (the
// consumer stopped draining), handleChunk must FAIL the request — terminal 499
// on ErrorCh, pending request removed — rather than silently dropping the
// chunk and delivering a corrupted-but-billed stream.
func TestHandleChunkOverflowFailsRequest(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	providerPublicKey := testPublicKeyB64()
	provider := reg.Register("provider-overflow", nil, &protocol.RegisterMessage{
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
		RequestID:      "req-overflow",
		Model:          "test-model",
		ChunkCh:        make(chan string, 1),
		CompleteCh:     make(chan protocol.UsageInfo, 1),
		ErrorCh:        make(chan protocol.InferenceErrorMessage, 1),
		SessionPrivKey: &sessionKeys.PrivateKey,
	}
	// Fill the chunk buffer so the next send would block: this simulates a
	// consumer that stopped draining (stalled TCP write / wedged handler).
	pr.ChunkCh <- "data: buffered-but-undrained"
	provider.AddPending(pr)

	// Deliver one more VALID encrypted chunk — decryption succeeds, but the
	// non-blocking send hits the full buffer.
	chunk := testEncryptedChunk(t, protocol.InferenceRequestMessage{
		RequestID: pr.RequestID,
		EncryptedBody: &protocol.EncryptedPayload{
			EphemeralPublicKey: base64.StdEncoding.EncodeToString(sessionKeys.PublicKey[:]),
			Ciphertext:         "",
		},
	}, providerPublicKey, `data: {"choices":[{"delta":{"content":"overflowing"}}]}`)

	srv.handleChunk(provider.ID, provider, &chunk)

	// (a) A terminal InferenceErrorMessage with StatusCode 499 arrives on
	// ErrorCh, and handleInferenceError then closes all three channels.
	select {
	case errMsg, ok := <-pr.ErrorCh:
		if !ok {
			t.Fatal("error channel closed before the 499 terminal was delivered")
		}
		if errMsg.StatusCode != 499 {
			t.Fatalf("status code = %d, want 499", errMsg.StatusCode)
		}
		want := "request cancelled: consumer stream stalled (chunk buffer overflow)"
		if errMsg.Error != want {
			t.Fatalf("error = %q, want %q", errMsg.Error, want)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for overflow terminal error")
	}
	if _, ok := <-pr.ErrorCh; ok {
		t.Fatal("error channel should be closed after the terminal error")
	}

	// The pre-filled (stale) chunk is still in the buffer; the overflowing
	// chunk must NOT have been delivered, and the channel must be closed.
	select {
	case got, ok := <-pr.ChunkCh:
		if !ok {
			t.Fatal("chunk channel closed before draining the buffered chunk")
		}
		if got != "data: buffered-but-undrained" {
			t.Fatalf("buffered chunk = %q, want the pre-filled one", got)
		}
	default:
		t.Fatal("chunk channel should still hold the pre-filled chunk")
	}
	if extra, ok := <-pr.ChunkCh; ok {
		t.Fatalf("overflowing chunk %q was delivered; channel should be closed instead", extra)
	}
	if _, ok := <-pr.CompleteCh; ok {
		t.Fatal("complete channel should be closed without a completion")
	}

	// (b) The pending request is removed.
	if provider.GetPending(pr.RequestID) != nil {
		t.Fatal("pending request still registered after overflow abort")
	}

	// The memoized chunk-decryption key is dropped (terminal cleanup).
	srv.chunkKeys.mu.Lock()
	_, keyCached := srv.chunkKeys.m[pr.SessionPrivKey]
	srv.chunkKeys.mu.Unlock()
	if keyCached {
		t.Error("chunk key cache entry should be forgotten on terminal error")
	}

	// (c) No reputation penalty: 499 + "request cancelled" classifies as a
	// consumer-side terminal in handleInferenceError, so RecordJobFailure is
	// skipped — TotalJobs stays 0 (same observability as provider_test.go's
	// capacity-rejection assertions).
	if got := provider.Reputation.TotalJobs; got != 0 {
		t.Errorf("Reputation.TotalJobs = %d, want 0 (backpressure abort is not a provider fault)", got)
	}
	if got := provider.Reputation.FailedJobs; got != 0 {
		t.Errorf("Reputation.FailedJobs = %d, want 0", got)
	}

	// The overflow is coordinator/consumer backpressure, not a provider
	// protocol violation — the provider must NOT be marked untrusted.
	got := reg.GetProvider(provider.ID)
	if got == nil {
		t.Fatal("provider disappeared from registry after overflow abort")
	}
	if got.Status == registry.StatusUntrusted {
		t.Fatalf("provider status = %v; overflow must not mark the provider untrusted", got.Status)
	}
}

// TestHandleChunkOverflowGraceDeliversToSlowConsumer pins the bounded-grace
// half of the overflow behavior: a consumer that is merely bursty — full
// buffer at arrival time but draining within chunkOverflowGrace — must get the
// chunk delivered and keep its stream alive, NOT be killed with a 499.
func TestHandleChunkOverflowGraceDeliversToSlowConsumer(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

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
		ChunkCh:        make(chan string, 1),
		CompleteCh:     make(chan protocol.UsageInfo, 1),
		ErrorCh:        make(chan protocol.InferenceErrorMessage, 1),
		SessionPrivKey: &sessionKeys.PrivateKey,
	}
	pr.ChunkCh <- "data: buffered-but-draining"
	provider.AddPending(pr)

	// Simulate a slow-but-alive consumer: drain one slot well within the
	// grace window while handleChunk is blocked in sendChunkWithGrace.
	drained := make(chan string, 1)
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

	srv.handleChunk(provider.ID, provider, &chunk)

	select {
	case first := <-drained:
		if first != "data: buffered-but-draining" {
			t.Fatalf("drained chunk = %q, want the pre-filled one", first)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for the drainer")
	}

	// The overflowing chunk must have been delivered into the freed slot.
	select {
	case got := <-pr.ChunkCh:
		if got == "" {
			t.Fatal("empty chunk delivered")
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
