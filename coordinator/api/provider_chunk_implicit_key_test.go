package api

// The chunk's ephemeral_public_key is redundant after registration: the
// coordinator derives the shared key from the provider's REGISTERED key, so a
// chunk sealed under any other key fails the symmetric open regardless of the
// field. Accepting an absent field as "the registered key" is a strict
// superset of the equality check (coordinator-first, additive: providers keep
// sending it until the fleet runs this coordinator). Driven through
// handleChunk, the real decrypt path, with real e2e keys.

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

type implicitKeyFixture struct {
	srv         *Server
	reg         *registry.Registry
	provider    *registry.Provider
	pr          *registry.PendingRequest
	providerKey string
	// sealKey is the provider key pair the test seals chunks with (the
	// registered key, or a throwaway one when nothing is registered).
	sealKey string
	session *e2e.SessionKeys
}

func newImplicitKeyFixture(t *testing.T, providerKey, sealKey string) *implicitKeyFixture {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	reg := registry.New(logger)
	srv := NewServer(reg, store.NewMemory(store.Config{AdminKey: "test-key"}), ServerConfig{}, logger)
	provider := reg.Register("provider-implicit", nil, &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
		PublicKey:               providerKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	})
	session, err := e2e.GenerateSessionKeys()
	if err != nil {
		t.Fatalf("generate session keys: %v", err)
	}
	pr := &registry.PendingRequest{
		RequestID:      "req-implicit",
		Model:          "test-model",
		ChunkCh:        make(chan registry.ProviderChunk, 1),
		CompleteCh:     make(chan protocol.UsageInfo, 1),
		ErrorCh:        make(chan protocol.InferenceErrorMessage, 1),
		SessionPrivKey: &session.PrivateKey,
	}
	provider.AddPending(pr)
	return &implicitKeyFixture{srv: srv, reg: reg, provider: provider, pr: pr, providerKey: providerKey, sealKey: sealKey, session: session}
}

// sealed seals plaintext with the real provider key pair the test helpers
// hold for providerKey, then overrides the ephemeral_public_key field.
func (f *implicitKeyFixture) sealed(t *testing.T, plaintext, ephemeralField string) protocol.InferenceResponseChunkMessage {
	t.Helper()
	chunk := testEncryptedChunk(t, protocol.InferenceRequestMessage{
		RequestID: f.pr.RequestID,
		EncryptedBody: &protocol.EncryptedPayload{
			EphemeralPublicKey: base64.StdEncoding.EncodeToString(f.session.PublicKey[:]),
		},
	}, f.sealKey, plaintext)
	chunk.EncryptedData.EphemeralPublicKey = ephemeralField
	return chunk
}

func (f *implicitKeyFixture) expectDelivered(t *testing.T, want string) {
	t.Helper()
	select {
	case got, ok := <-f.pr.ChunkCh:
		if !ok {
			t.Fatal("chunk channel closed: the chunk was rejected")
		}
		if got.Data != want {
			t.Fatalf("chunk = %q, want %q", got.Data, want)
		}
	case errMsg := <-f.pr.ErrorCh:
		t.Fatalf("chunk was rejected: %+v", errMsg)
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for the decrypted chunk")
	}
}

func (f *implicitKeyFixture) expectRejected(t *testing.T) {
	t.Helper()
	select {
	case got, ok := <-f.pr.ChunkCh:
		if ok {
			t.Fatalf("chunk %q was delivered, want the encryption-failure terminal", got.Data)
		}
		// Closed by the terminal: read the terminal itself below.
		errMsg, ok := <-f.pr.ErrorCh
		if !ok {
			t.Fatal("error channel closed without the encryption-failure terminal")
		}
		if errMsg.FailureCode != protocol.FailureCodeEncryptionFailure {
			t.Fatalf("terminal = %+v, want encryption_failure", errMsg)
		}
	case errMsg := <-f.pr.ErrorCh:
		if errMsg.FailureCode != protocol.FailureCodeEncryptionFailure {
			t.Fatalf("terminal = %+v, want encryption_failure", errMsg)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for the rejection terminal")
	}
	if p := f.reg.GetProvider(f.provider.ID); p != nil {
		p.Mu().Lock()
		status := p.Status
		p.Mu().Unlock()
		if status != registry.StatusUntrusted {
			t.Fatalf("provider status = %q after a chunk violation, want untrusted", status)
		}
	}
}

// TestHandleChunkAcceptsAbsentEphemeralKeyAsRegisteredKey: an empty
// ephemeral_public_key decrypts exactly like the registered key — the
// behaviour this coordinator must have fleet-wide before a provider release
// may omit the field.
func TestHandleChunkAcceptsAbsentEphemeralKeyAsRegisteredKey(t *testing.T) {
	key := testPublicKeyB64()
	f := newImplicitKeyFixture(t, key, key)
	const want = `data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"implicit"}}]}`
	chunk := f.sealed(t, want, "")
	f.srv.handleChunk(f.provider.ID, f.provider, &chunk)
	f.expectDelivered(t, want)
}

// TestHandleChunkRegisteredEphemeralKeyStillDecrypts: today's providers keep
// sending the registered key; nothing changes for them.
func TestHandleChunkRegisteredEphemeralKeyStillDecrypts(t *testing.T) {
	key := testPublicKeyB64()
	f := newImplicitKeyFixture(t, key, key)
	const want = `data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"explicit"}}]}`
	chunk := f.sealed(t, want, f.providerKey)
	f.srv.handleChunk(f.provider.ID, f.provider, &chunk)
	f.expectDelivered(t, want)
}

// TestHandleChunkWrongEphemeralKeyStillRejected: a present field that is not
// the registered key is still the sender-key violation (the provider is
// marked untrusted and the request gets the encryption-failure terminal).
func TestHandleChunkWrongEphemeralKeyStillRejected(t *testing.T) {
	key := testPublicKeyB64()
	f := newImplicitKeyFixture(t, key, key)
	other := make([]byte, 32)
	other[0] = 7
	chunk := f.sealed(t, `data: {"choices":[{"delta":{"content":"x"}}]}`, base64.StdEncoding.EncodeToString(other))
	f.srv.handleChunk(f.provider.ID, f.provider, &chunk)
	f.expectRejected(t)
}

// TestHandleChunkAbsentEphemeralKeyWithoutRegisteredKeyRejected: a provider
// with no registered key cannot rely on the implicit form either.
func TestHandleChunkAbsentEphemeralKeyWithoutRegisteredKeyRejected(t *testing.T) {
	f := newImplicitKeyFixture(t, "", testPublicKeyB64())
	chunk := f.sealed(t, `data: {"choices":[{"delta":{"content":"x"}}]}`, "")
	f.srv.handleChunk(f.provider.ID, f.provider, &chunk)
	f.expectRejected(t)
}
