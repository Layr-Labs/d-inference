package api

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// Lifecycle tests for the chunk-key cache terminal paths: every way a request
// can end must drop its memoized X25519 shared key (and only read-loop
// terminals may zero it — see chunkKeyCache's zeroing policy).

// chunkKeyCached reports whether the cache currently holds an entry for priv.
func chunkKeyCached(c *chunkKeyCache, priv *[32]byte) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	_, ok := c.m[priv]
	return ok
}

// seedChunkKey populates srv.chunkKeys for pr's session key against a fresh
// peer public key, returning the cached shared-key pointer.
func seedChunkKey(t *testing.T, srv *Server, priv *[32]byte) *[32]byte {
	t.Helper()
	peerPub, _, _ := testPeerKeyB64(t)
	shared, err := srv.chunkKeys.sharedKey(priv, peerPub)
	if err != nil {
		t.Fatalf("seed sharedKey: %v", err)
	}
	return shared
}

// handleInferenceError is a read-loop terminal: the key is removed AND zeroed.
func TestHandleInferenceErrorForgetsAndZeroesChunkKey(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	reg := registry.New(logger)
	srv := &Server{registry: reg, logger: logger}

	p := reg.Register("prov-err-key", nil, &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: "key-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:  "mlx-swift",
	})

	priv := &[32]byte{7}
	pr := &registry.PendingRequest{
		RequestID:      "req-err-key",
		ProviderID:     p.ID,
		Model:          "key-model",
		SessionPrivKey: priv,
		ChunkCh:        make(chan string, 1),
		CompleteCh:     make(chan protocol.UsageInfo, 1),
		ErrorCh:        make(chan protocol.InferenceErrorMessage, 1),
	}
	p.AddPending(pr)
	shared := seedChunkKey(t, srv, priv)

	srv.handleInferenceError(p.ID, p, &protocol.InferenceErrorMessage{
		Type:       protocol.TypeInferenceError,
		RequestID:  pr.RequestID,
		Error:      "model crashed during generation",
		StatusCode: 500,
	})

	if chunkKeyCached(&srv.chunkKeys, priv) {
		t.Fatal("handleInferenceError should forget the chunk key")
	}
	if *shared != ([32]byte{}) {
		t.Error("read-loop terminal should zero the shared key (forgetAndZero)")
	}
}

// cancelDispatch (the dispatch-loop abandon seam: speculative losers,
// failover retries) drops the key WITHOUT zeroing — it runs cross-goroutine
// from the provider read loop.
func TestCancelDispatchAndForgetDropsKeyWithoutZeroing(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	reg := registry.New(logger)
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	srv := NewServer(reg, st, ServerConfig{}, logger)

	p := reg.Register("prov-cancel-key", nil, &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: "key-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:  "mlx-swift",
	})

	priv := &[32]byte{9}
	pr := &registry.PendingRequest{
		RequestID:      "req-cancel-key",
		ProviderID:     p.ID,
		Model:          "key-model",
		SessionPrivKey: priv,
	}
	p.AddPending(pr)
	shared := seedChunkKey(t, srv, priv)
	want := *shared

	srv.cancelDispatch(p, pr)

	if p.GetPending(pr.RequestID) != nil {
		t.Fatal("cancelDispatch should remove the pending request")
	}
	if chunkKeyCached(&srv.chunkKeys, priv) {
		t.Fatal("cancelDispatch should forget the chunk key")
	}
	if *shared != want {
		t.Error("cross-goroutine forget must NOT zero the shared key")
	}
	// nil pr must be a no-op, not a panic.
	srv.cancelDispatch(p, nil)
}

// The queued-retry reassignment contract (dispatchPrimary ~line 905): the OLD
// SessionPrivKey must be forgotten BEFORE the pointer is overwritten, or its
// cache entry is orphaned forever (the cache is keyed by pointer identity).
// This exercises the exact forget-then-reassign sequence the dispatch path
// performs, on a shared PendingRequest object.
func TestRetryReassignmentForgetsOldChunkKey(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	srv := &Server{logger: logger}

	oldKey := &[32]byte{1}
	pr := &registry.PendingRequest{RequestID: "req-retry", SessionPrivKey: oldKey}
	oldShared := seedChunkKey(t, srv, pr.SessionPrivKey)
	want := *oldShared

	// The dispatch retry seam: forget the old key, then overwrite the pointer.
	srv.chunkKeys.forget(pr.SessionPrivKey)
	newKey := &[32]byte{2}
	pr.SessionPrivKey = newKey

	if chunkKeyCached(&srv.chunkKeys, oldKey) {
		t.Fatal("old session key must be forgotten before reassignment")
	}
	if *oldShared != want {
		t.Error("retry reassignment is cross-goroutine: the old shared key must not be zeroed")
	}
	// The new key works independently.
	if seedChunkKey(t, srv, pr.SessionPrivKey) == nil {
		t.Fatal("new session key should be cacheable")
	}
	if !chunkKeyCached(&srv.chunkKeys, newKey) {
		t.Fatal("new session key entry missing")
	}
}

// forgetProviderPendingKeys (the providerReadLoop cleanup helper) drops and
// zeroes every pending request's key, and tolerates nil providers and requests
// without keys.
func TestForgetProviderPendingKeysDirect(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	reg := registry.New(logger)
	srv := &Server{registry: reg, logger: logger}

	srv.forgetProviderPendingKeys(nil) // never-registered provider: no-op

	p := reg.Register("prov-disc-key", nil, &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: "key-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:  "mlx-swift",
	})

	privA := &[32]byte{3}
	privB := &[32]byte{4}
	p.AddPending(&registry.PendingRequest{RequestID: "req-a", SessionPrivKey: privA})
	p.AddPending(&registry.PendingRequest{RequestID: "req-b", SessionPrivKey: privB})
	p.AddPending(&registry.PendingRequest{RequestID: "req-nokey"})

	sharedA := seedChunkKey(t, srv, privA)
	sharedB := seedChunkKey(t, srv, privB)

	srv.forgetProviderPendingKeys(p)

	if chunkKeyCached(&srv.chunkKeys, privA) || chunkKeyCached(&srv.chunkKeys, privB) {
		t.Fatal("disconnect cleanup should forget every pending session key")
	}
	if *sharedA != ([32]byte{}) || *sharedB != ([32]byte{}) {
		t.Error("disconnect cleanup runs on the read-loop goroutine: keys must be zeroed")
	}
}

// End-to-end: a REGISTRY-INITIATED disconnect (stale eviction, duplicate-
// serial eviction, forced removal — anything that calls Registry.Disconnect
// directly) wipes the provider's pending map BEFORE its CloseNow unblocks the
// read loop, so the defer's per-request key snapshot is empty. The peer-key
// sweep (chunkKeys.forgetPeer) must still drop every entry cached under the
// provider's public key — WITHOUT zeroing, since a same-keypair replacement
// session could be decrypting with a matching entry.
func TestRegistryInitiatedDisconnectSweepsChunkKeys(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "test done")

	peerPubB64, _, _ := testPeerKeyB64(t)
	regMsg := protocol.RegisterMessage{
		Type:      protocol.TypeRegister,
		Hardware:  protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64},
		Models:    []protocol.ModelInfo{{ID: "evict-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:   "mlx-swift",
		PublicKey: peerPubB64,
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}

	deadline := time.Now().Add(5 * time.Second)
	var p *registry.Provider
	for time.Now().Before(deadline) {
		if p = findProviderByModel(reg, "evict-model"); p != nil {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if p == nil {
		t.Fatal("provider never registered")
	}

	priv := &[32]byte{6}
	p.AddPending(&registry.PendingRequest{
		RequestID:      "req-evicted",
		ProviderID:     p.ID,
		Model:          "evict-model",
		SessionPrivKey: priv,
		ChunkCh:        make(chan string, 1),
		CompleteCh:     make(chan protocol.UsageInfo, 1),
		ErrorCh:        make(chan protocol.InferenceErrorMessage, 1),
	})
	// The real decrypt path caches under the provider's registered public key.
	shared, err := srv.chunkKeys.sharedKey(priv, p.PublicKey)
	if err != nil {
		t.Fatalf("seed sharedKey under provider key: %v", err)
	}
	want := *shared

	// Registry-initiated: wipes the pending map, THEN CloseNow unblocks the
	// server read loop, whose defer must sweep by peer key.
	reg.Disconnect(p.ID)

	for time.Now().Before(deadline) {
		if !chunkKeyCached(&srv.chunkKeys, priv) {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if chunkKeyCached(&srv.chunkKeys, priv) {
		t.Fatal("registry-initiated disconnect never swept the orphaned chunk key")
	}
	if *shared != want {
		t.Error("the peer-key sweep must NOT zero (possible same-keypair replacement session)")
	}
}

// End-to-end: a provider WebSocket disconnect runs providerReadLoop's cleanup
// defer, which must forget (and zero) the chunk keys of every request still
// in-flight on that provider — BEFORE registry.Disconnect wipes the pending map.
func TestProviderDisconnectForgetsPendingChunkKeys(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}

	regMsg := protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: "disc-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:  "mlx-swift",
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}

	deadline := time.Now().Add(5 * time.Second)
	var p *registry.Provider
	for time.Now().Before(deadline) {
		if p = findProviderByModel(reg, "disc-model"); p != nil {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if p == nil {
		t.Fatal("provider never registered")
	}

	priv := &[32]byte{5}
	p.AddPending(&registry.PendingRequest{
		RequestID:      "req-inflight",
		ProviderID:     p.ID,
		Model:          "disc-model",
		SessionPrivKey: priv,
		ChunkCh:        make(chan string, 1),
		CompleteCh:     make(chan protocol.UsageInfo, 1),
		ErrorCh:        make(chan protocol.InferenceErrorMessage, 1),
	})
	shared := seedChunkKey(t, srv, priv)

	// Client-side close: the read loop exits and its cleanup defer runs.
	conn.Close(websocket.StatusNormalClosure, "bye")

	for time.Now().Before(deadline) {
		if !chunkKeyCached(&srv.chunkKeys, priv) {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if chunkKeyCached(&srv.chunkKeys, priv) {
		t.Fatal("disconnect cleanup never forgot the in-flight request's chunk key")
	}
	// forgetAndZero zeroes under the same lock that deletes: once the entry is
	// gone, the array must already be scrubbed.
	if *shared != ([32]byte{}) {
		t.Error("disconnect cleanup should zero the shared key (read-loop goroutine)")
	}
	if got := reg.ProviderCount(); got != 0 {
		// Disconnect runs after the forget in the same defer; give it a beat.
		time.Sleep(100 * time.Millisecond)
		if got = reg.ProviderCount(); got != 0 {
			t.Fatalf("provider count after disconnect = %d, want 0", got)
		}
	}
}
