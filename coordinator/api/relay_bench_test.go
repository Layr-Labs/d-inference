package api

// Benchmarks for the provider-side half of the streaming relay: one WebSocket
// frame (one token) from the read loop's decode through handleChunk (pending
// lookup, decrypt, boilerplate classification, channel hand-off). The fixture
// encrypts a Swift-shaped content delta with real X25519/NaCl keys and renders
// the frame in the Swift provider's sorted-key wire order.

import (
	"encoding/json"
	"log/slog"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// relayBenchContentChunk is a content delta as the Swift provider emits it
// (JSONEncoder .sortedKeys; nil optionals omitted, never null).
const relayBenchContentChunk = `data: {"choices":[{"delta":{"content":" the"},"index":0}],"created":1756800000,"id":"chatcmpl-7f3a2b1c","model":"mlx-community/gemma-4-26B-A4B-it-qat-4bit","object":"chat.completion.chunk"}`

type relayBenchFixture struct {
	srv      *Server
	provider *registry.Provider
	pr       *registry.PendingRequest
	frame    []byte // Swift-shaped WS frame
}

func newRelayBenchFixture(b *testing.B) *relayBenchFixture {
	b.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	providerPublicKey := testPublicKeyB64()
	provider := reg.Register("provider-bench", nil, &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", ChipFamily: "M3", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
		PublicKey:               providerPublicKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	})
	sessionKeys, err := e2e.GenerateSessionKeys()
	if err != nil {
		b.Fatal(err)
	}
	pr := &registry.PendingRequest{
		RequestID:      "0f3a9c1e-6b7d-4a2e-9c5f-1d2e3f4a5b6c",
		Model:          "test-model",
		PublicModel:    "gemma-4-26b",
		ChunkCh:        make(chan registry.ProviderChunk, chunkBufferSize),
		CompleteCh:     make(chan protocol.UsageInfo, 1),
		ErrorCh:        make(chan protocol.InferenceErrorMessage, 1),
		SessionPrivKey: &sessionKeys.PrivateKey,
	}
	provider.AddPending(pr)

	value, _ := testProviderKeys.Load(providerPublicKey)
	kp := value.(testProviderKeyPair)
	payload, err := e2e.Encrypt([]byte(relayBenchContentChunk), sessionKeys.PublicKey,
		&e2e.SessionKeys{PublicKey: kp.public, PrivateKey: kp.private})
	if err != nil {
		b.Fatal(err)
	}
	frame := `{"encrypted_data":{"ciphertext":"` + payload.Ciphertext +
		`","ephemeral_public_key":"` + payload.EphemeralPublicKey +
		`"},"request_id":"` + pr.RequestID +
		`","type":"` + protocol.TypeInferenceResponseChunk + `"}`
	return &relayBenchFixture{srv: srv, provider: provider, pr: pr, frame: []byte(frame)}
}

// handleChunk alone (lookup + decrypt + classify + channel send).
func BenchmarkRelay_HandleChunk(b *testing.B) {
	f := newRelayBenchFixture(b)
	var pm protocol.ProviderMessage
	if err := protocol.DecodeProviderMessage(f.frame, &pm); err != nil {
		b.Fatal(err)
	}
	msg := pm.Payload.(*protocol.InferenceResponseChunkMessage)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		f.srv.handleChunk(f.provider.ID, f.provider, msg)
		<-f.pr.ChunkCh
	}
}

// The read loop's per-frame work as it stands now: DecodeProviderMessage
// (chunk fast path) + handleChunk.
func BenchmarkRelay_ReadLoopPerFrame(b *testing.B) {
	f := newRelayBenchFixture(b)
	b.ReportAllocs()
	b.SetBytes(int64(len(f.frame)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var pm protocol.ProviderMessage
		if err := protocol.DecodeProviderMessage(f.frame, &pm); err != nil {
			b.Fatal(err)
		}
		f.srv.handleChunk(f.provider.ID, f.provider, pm.Payload.(*protocol.InferenceResponseChunkMessage))
		<-f.pr.ChunkCh
	}
}

// Permanent baseline: the same per-frame work with encoding/json decoding the
// frame (what the read loop paid before the hand-written chunk decoder).
func BenchmarkRelay_ReadLoopPerFrame_GenericDecode(b *testing.B) {
	f := newRelayBenchFixture(b)
	b.ReportAllocs()
	b.SetBytes(int64(len(f.frame)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var msg protocol.InferenceResponseChunkMessage
		if err := json.Unmarshal(f.frame, &msg); err != nil {
			b.Fatal(err)
		}
		f.srv.handleChunk(f.provider.ID, f.provider, &msg)
		<-f.pr.ChunkCh
	}
}
