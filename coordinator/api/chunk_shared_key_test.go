package api

import (
	"crypto/rand"
	"encoding/base64"
	"log/slog"
	"os"
	"testing"

	"golang.org/x/crypto/nacl/box"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// testPeerKeyB64 generates a fresh X25519 keypair and returns the base64
// public key plus the raw pair, standing in for a provider's registered key.
func testPeerKeyB64(t *testing.T) (string, *[32]byte, *[32]byte) {
	t.Helper()
	pub, priv, err := box.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate peer keys: %v", err)
	}
	return base64.StdEncoding.EncodeToString(pub[:]), pub, priv
}

func sharedKeyTestServer(t *testing.T) *Server {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	return NewServer(registry.New(logger), store.NewMemory(store.Config{AdminKey: "k"}), ServerConfig{}, logger)
}

// sealedChunkFor seals plaintext from the provider (peer) to the request's
// session key, as the Swift provider does per token.
func sealedChunkFor(t *testing.T, plaintext string, session *e2e.SessionKeys, peerPub, peerPriv *[32]byte) *protocol.InferenceResponseChunkMessage {
	t.Helper()
	payload, err := e2e.Encrypt([]byte(plaintext), session.PublicKey, &e2e.SessionKeys{PublicKey: *peerPub, PrivateKey: *peerPriv})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}
	return &protocol.InferenceResponseChunkMessage{
		Type:          protocol.TypeInferenceResponseChunk,
		RequestID:     "req",
		EncryptedData: &protocol.EncryptedPayload{EphemeralPublicKey: payload.EphemeralPublicKey, Ciphertext: payload.Ciphertext},
	}
}

// TestDecryptTextResponseChunkUsesPrecomputedSharedKey: the key the dispatcher
// precomputes next to SessionPrivKey is the real NaCl box key — a chunk sealed
// by the provider opens with it, matching the e2e.Decrypt reference path — and
// the decrypt path neither replaces nor recomputes it.
func TestDecryptTextResponseChunkUsesPrecomputedSharedKey(t *testing.T) {
	srv := sharedKeyTestServer(t)
	peerPubB64, peerPub, peerPriv := testPeerKeyB64(t)
	provider := &registry.Provider{ID: "p", PublicKey: peerPubB64}
	session, err := e2e.GenerateSessionKeys()
	if err != nil {
		t.Fatal(err)
	}
	shared := e2e.PrecomputeSharedKey(peerPub, &session.PrivateKey)
	pr := &registry.PendingRequest{RequestID: "req", SessionPrivKey: &session.PrivateKey, SharedKey: shared}

	const plaintext = `data: {"choices":[{"delta":{"content":"tok"}}]}`
	got, err := srv.decryptTextResponseChunk(provider, pr, sealedChunkFor(t, plaintext, session, peerPub, peerPriv))
	if err != nil {
		t.Fatalf("decrypt: %v", err)
	}
	if got != plaintext {
		t.Fatalf("decrypted = %q, want %q", got, plaintext)
	}
	if pr.SharedKey != shared {
		t.Fatal("decrypt path replaced the precomputed shared key")
	}
}

// TestDecryptTextResponseChunkDerivesSharedKeyOnceWhenAbsent: a pending
// request built without SharedKey (tests, any future constructor) derives it
// on the first chunk — exactly the key the dispatcher would have precomputed —
// and every later chunk reuses that same pointer. A missing key is never a
// decrypt failure (which would MarkUntrusted the provider).
func TestDecryptTextResponseChunkDerivesSharedKeyOnceWhenAbsent(t *testing.T) {
	srv := sharedKeyTestServer(t)
	peerPubB64, peerPub, peerPriv := testPeerKeyB64(t)
	provider := &registry.Provider{ID: "p", PublicKey: peerPubB64}
	session, err := e2e.GenerateSessionKeys()
	if err != nil {
		t.Fatal(err)
	}
	pr := &registry.PendingRequest{RequestID: "req", SessionPrivKey: &session.PrivateKey}

	if _, err := srv.decryptTextResponseChunk(provider, pr, sealedChunkFor(t, "first", session, peerPub, peerPriv)); err != nil {
		t.Fatalf("first decrypt: %v", err)
	}
	if pr.SharedKey == nil {
		t.Fatal("first decrypt did not derive the shared key onto the pending request")
	}
	first := pr.SharedKey
	if *first != *e2e.PrecomputeSharedKey(peerPub, &session.PrivateKey) {
		t.Fatal("lazily derived key differs from PrecomputeSharedKey")
	}
	got, err := srv.decryptTextResponseChunk(provider, pr, sealedChunkFor(t, "second", session, peerPub, peerPriv))
	if err != nil || got != "second" {
		t.Fatalf("second decrypt = %q, %v", got, err)
	}
	if pr.SharedKey != first {
		t.Fatal("second chunk re-derived the shared key instead of reusing it")
	}
}

// TestDecryptTextResponseChunkDistinctKeysPerRequest: two concurrent requests
// on one provider each carry their own session + shared key; each opens only
// its own chunks.
func TestDecryptTextResponseChunkDistinctKeysPerRequest(t *testing.T) {
	srv := sharedKeyTestServer(t)
	peerPubB64, peerPub, peerPriv := testPeerKeyB64(t)
	provider := &registry.Provider{ID: "p", PublicKey: peerPubB64}
	newPR := func(id string) (*registry.PendingRequest, *e2e.SessionKeys) {
		session, err := e2e.GenerateSessionKeys()
		if err != nil {
			t.Fatal(err)
		}
		return &registry.PendingRequest{
			RequestID:      id,
			SessionPrivKey: &session.PrivateKey,
			SharedKey:      e2e.PrecomputeSharedKey(peerPub, &session.PrivateKey),
		}, session
	}
	prA, sessA := newPR("a")
	prB, sessB := newPR("b")
	if *prA.SharedKey == *prB.SharedKey {
		t.Fatal("two requests derived the same shared key")
	}
	chunkA := sealedChunkFor(t, "for-a", sessA, peerPub, peerPriv)
	chunkB := sealedChunkFor(t, "for-b", sessB, peerPub, peerPriv)
	if got, err := srv.decryptTextResponseChunk(provider, prA, chunkA); err != nil || got != "for-a" {
		t.Fatalf("A decrypt = %q, %v", got, err)
	}
	if got, err := srv.decryptTextResponseChunk(provider, prB, chunkB); err != nil || got != "for-b" {
		t.Fatalf("B decrypt = %q, %v", got, err)
	}
	if _, err := srv.decryptTextResponseChunk(provider, prA, chunkB); err == nil {
		t.Fatal("request A opened a chunk sealed for request B")
	}
}

// TestModelAliasRewriterMatchesRewriteChunkModel: the per-request rewriter
// produces byte-identical output to the historical per-chunk rewrite on every
// chunk shape, and an alias-free chunk (every content delta after the first)
// costs zero allocations.
func TestModelAliasRewriterMatchesRewriteChunkModel(t *testing.T) {
	pr := &registry.PendingRequest{Model: "mlx-community/gemma-4-26B-A4B-it-qat-4bit", PublicModel: "gemma-4-26b"}
	corpus := []string{
		`data: {"choices":[{"delta":{"content":" the"},"index":0}],"created":1,"id":"c","model":"mlx-community/gemma-4-26B-A4B-it-qat-4bit","object":"chat.completion.chunk"}`,
		`data: {"choices":[{"delta":{"content":" the"},"index":0}],"created":1,"id":"c","model": "mlx-community/gemma-4-26B-A4B-it-qat-4bit","object":"chat.completion.chunk"}`,
		`data: {"choices":[{"delta":{"content":" the"},"index":0}]}`,
		`data: {"model":"mlx-community/gemma-4-26B-A4B-it-qat-4bit","x":{"model":"mlx-community/gemma-4-26B-A4B-it-qat-4bit"}}`,
		`data: {"model":"other-model"}`,
		``,
	}
	rw := newModelAliasRewriter(pr)
	for _, chunk := range corpus {
		if got, want := rw.rewrite(chunk), rewriteChunkModel(chunk, pr); got != want {
			t.Fatalf("rewrite(%q) = %q, want %q", chunk, got, want)
		}
	}
	plain := corpus[2]
	if allocs := testing.AllocsPerRun(100, func() { _ = rw.rewrite(plain) }); allocs != 0 {
		t.Fatalf("alias-free chunk cost %.0f allocs, want 0", allocs)
	}
	inactive := newModelAliasRewriter(&registry.PendingRequest{Model: "m", PublicModel: "m"})
	if allocs := testing.AllocsPerRun(100, func() { _ = inactive.rewrite(corpus[0]) }); allocs != 0 {
		t.Fatalf("alias-less request cost %.0f allocs, want 0", allocs)
	}
}
