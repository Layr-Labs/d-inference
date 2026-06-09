package api

// Regression tests for the "zombie connection" bug: removing a provider from
// the registry must also close its WebSocket. Previously Disconnect left the
// socket open, so the provider never detected the drop and never reconnected.

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

// dialAndRegisterProvider connects + registers a provider and returns the client
// conn and server-assigned ID. Fails the test if registration doesn't land.
func dialAndRegisterProvider(t *testing.T, ctx context.Context, ts *httptest.Server, reg *registry.Registry) (*websocket.Conn, string) {
	t.Helper()
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}

	regMsg := protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel: "Mac15,8",
			ChipName:     "Apple M3 Max",
			MemoryGB:     64,
		},
		Models: []protocol.ModelInfo{
			{ID: "test-model", SizeBytes: 1000, ModelType: "chat", Quantization: "4bit"},
		},
		Backend: "mlx-swift",
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}

	// Wait for the server-side registration to land.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if ids := reg.ProviderIDs(); len(ids) == 1 {
			return conn, ids[0]
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("provider did not register within deadline (count=%d)", reg.ProviderCount())
	return nil, ""
}

// assertSocketClosed fails unless the server tears down the client connection
// shortly after the provider leaves the registry (the zombie regression). The
// Read uses a background context, NOT a deadline: nhooyr closes the conn when a
// Read context expires, which would mask the bug. A wall-clock timer bounds the
// wait; pre-teardown messages (e.g. trust-status) are drained.
func assertSocketClosed(t *testing.T, conn *websocket.Conn) {
	t.Helper()
	closed := make(chan struct{})
	go func() {
		defer close(closed)
		for {
			if _, _, err := conn.Read(context.Background()); err != nil {
				return
			}
		}
	}()
	select {
	case <-closed: // Read errored => server tore the socket down. Pass.
	case <-time.After(2 * time.Second):
		t.Fatal("provider socket stayed open after registry removal (zombie connection): " +
			"Read did not unblock within 2s")
	}
}

func newEvictionTestServer(t *testing.T) (*Server, *registry.Registry, *httptest.Server) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.skipChallenge = true // keep the wire quiet apart from registration
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return srv, reg, ts
}

// TestDisconnectClosesProviderSocket: Disconnect must close the socket, not just
// drop the map entry. Without the fix the client Read never unblocks (zombie).
func TestDisconnectClosesProviderSocket(t *testing.T) {
	_, reg, ts := newEvictionTestServer(t)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	conn, id := dialAndRegisterProvider(t, ctx, ts, reg)
	defer conn.Close(websocket.StatusNormalClosure, "")

	reg.Disconnect(id)

	assertSocketClosed(t, conn)

	if reg.ProviderCount() != 0 {
		t.Errorf("provider count after disconnect = %d, want 0", reg.ProviderCount())
	}
}

// TestStaleEvictionClosesProviderSocket: a provider that stops heartbeating is
// evicted, and that eviction must close the socket so it detects the drop and
// reconnects. The reported scenario.
func TestStaleEvictionClosesProviderSocket(t *testing.T) {
	_, reg, ts := newEvictionTestServer(t)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	conn, _ := dialAndRegisterProvider(t, ctx, ts, reg)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Short timeout + no heartbeats: provider goes stale and is evicted (ticker = timeout/3).
	evictCtx, evictCancel := context.WithCancel(context.Background())
	defer evictCancel()
	reg.StartEvictionLoop(evictCtx, 100*time.Millisecond)

	assertSocketClosed(t, conn)

	if reg.ProviderCount() != 0 {
		t.Errorf("provider count after eviction = %d, want 0", reg.ProviderCount())
	}
}
