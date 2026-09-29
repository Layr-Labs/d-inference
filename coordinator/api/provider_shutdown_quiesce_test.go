package api

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"nhooyr.io/websocket"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Shutdown closes every provider socket and joins its handler before the
// final cache routing flush, so no receipt or heartbeat can arrive behind it;
// afterwards new provider sockets are refused.
func TestCloseProviderConnectionsJoinsHandlersAndRefusesNewOnes(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	const rawToken = "eigeninference-pt-shutdown-quiesce-test"
	if err := st.CreateProviderToken(&store.ProviderToken{TokenHash: sha256Hash(rawToken), AccountID: "acct-quiesce", Active: true}); err != nil {
		t.Fatalf("create provider token: %v", err)
	}
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	t.Cleanup(func() { _ = conn.CloseNow() })
	regMsg := protocol.RegisterMessage{
		Type:      protocol.TypeRegister,
		Hardware:  protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:    []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:   "mlx-swift",
		AuthToken: rawToken,
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}
	waitFor(t, 5*time.Second, "provider registered", func() bool { return len(reg.ProviderIDs()) == 1 })
	// A second socket that never sends its register frame: the registry
	// does not know it, so the close must reach it through the server's
	// own tracking or the join would wait for it until exit.
	silent, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial (silent): %v", err)
	}
	t.Cleanup(func() { _ = silent.CloseNow() })
	waitFor(t, 5*time.Second, "silent socket tracked", func() bool {
		srv.providerAdmit.Lock()
		defer srv.providerAdmit.Unlock()
		return len(srv.providerConns) == 2
	})

	closeCtx, closeCancel := context.WithTimeout(ctx, 5*time.Second)
	defer closeCancel()
	if !srv.CloseProviderConnections(closeCtx) {
		t.Fatal("provider socket handlers did not finish before the deadline")
	}
	// The handler was joined, so the provider is already torn down through
	// the ordinary disconnect path and the client's socket is dead.
	if ids := reg.ProviderIDs(); len(ids) != 0 {
		t.Fatalf("provider still registered after its socket was closed: %v", ids)
	}
	// Frames the coordinator queued before the close (challenges, welcome)
	// may still be readable; the socket itself must be dead, not merely idle.
	readCtx, readCancel := context.WithTimeout(ctx, 5*time.Second)
	defer readCancel()
	for {
		_, _, err := conn.Read(readCtx)
		if err == nil {
			continue
		}
		if errors.Is(err, context.DeadlineExceeded) {
			t.Fatal("provider socket still open after CloseProviderConnections")
		}
		break
	}
	if _, _, err := silent.Read(readCtx); err == nil {
		t.Fatal("the unregistered socket must be closed too")
	}
	// No new provider socket is accepted behind the final flush.
	_, resp, err := websocket.Dial(ctx, wsURL, nil)
	if err == nil || resp == nil || resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("new provider socket must be refused with 503: err=%v resp=%v", err, resp)
	}
	if reg.ProviderIDs() != nil && len(reg.ProviderIDs()) != 0 {
		t.Fatalf("refused socket registered a provider: %v", reg.ProviderIDs())
	}
}

// WaitProviderHandlers may be called again after a timed-out join; it
// reports true once the last admitted handler has returned.
func TestWaitProviderHandlersReportsLateHandlers(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	// Before the close the wait is a programming error and reports false.
	if srv.WaitProviderHandlers(shortCtx(t, 50*time.Millisecond)) {
		t.Fatal("wait before the close must be refused")
	}
	// An admitted handler that is still running when the close begins.
	srv.providerAdmit.Lock()
	srv.providerHandlers.Add(1)
	srv.providerAdmit.Unlock()
	if srv.CloseProviderConnections(shortCtx(t, 50*time.Millisecond)) {
		t.Fatal("close must report the running handler")
	}
	if srv.WaitProviderHandlers(shortCtx(t, 50*time.Millisecond)) {
		t.Fatal("wait must time out while the handler runs")
	}
	srv.providerHandlers.Done()
	if !srv.WaitProviderHandlers(shortCtx(t, time.Second)) {
		t.Fatal("wait must return true once the handler has returned")
	}
}

func shortCtx(t *testing.T, d time.Duration) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), d)
	t.Cleanup(cancel)
	return ctx
}
