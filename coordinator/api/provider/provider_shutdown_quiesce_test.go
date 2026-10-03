package provider

import "github.com/eigeninference/d-inference/coordinator/api/observation"

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"nhooyr.io/websocket"
	"os"
	"strings"
	"testing"
	"time"
)

// Shutdown closes every provider socket and joins its handler before the
// final cache routing flush, so no receipt or heartbeat can arrive behind it;
// afterwards new provider sockets are refused.
func TestCloseProviderConnectionsJoinsHandlersAndRefusesNewOnes(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := newProviderFixture(t, Dependencies{Registry: reg, Store: st, Logger: logger})
	ts := httptest.NewServer(http.HandlerFunc(srv.HandleProviderWS))
	t.Cleanup(ts.Close)
	const rawToken = "eigeninference-pt-shutdown-quiesce-test"
	if err := st.CreateProviderToken(&store.ProviderToken{TokenHash: providerTokenHash(rawToken), AccountID: "acct-quiesce", Active: true}); err != nil {
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
	srv := newProviderFixture(t, Dependencies{Registry: registry.New(logger), Store: memory.NewMemory(store.Config{}), Logger: logger})
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

// A registration processed after shutdown began closing sockets is torn
// down with its session row stamped coordinator_shutdown, like a session
// whose socket the close reached, not with the registry's generic reason.
func TestLateRegistrationDuringShutdownIsStampedCoordinatorShutdown(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := newProviderFixture(t, Dependencies{Registry: reg, Store: st, Logger: logger})
	ts := httptest.NewServer(http.HandlerFunc(srv.HandleProviderWS))
	t.Cleanup(ts.Close)
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	t.Cleanup(func() { _ = conn.CloseNow() })
	waitFor(t, 5*time.Second, "socket tracked", func() bool {
		srv.providerAdmit.Lock()
		defer srv.providerAdmit.Unlock()
		return len(srv.providerConns) == 1
	})
	// Admitted before the close began; its register frame is processed
	// after.
	srv.providerAdmit.Lock()
	srv.providersClosing = true
	srv.providerAdmit.Unlock()
	regMsg := protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:  "mlx-swift",
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}
	waitCtx, waitCancel := context.WithTimeout(ctx, 5*time.Second)
	defer waitCancel()
	if !srv.WaitProviderHandlers(waitCtx) {
		t.Fatal("the late registration's handler did not return")
	}
	if ids := reg.ProviderIDs(); len(ids) != 0 {
		t.Fatalf("provider still registered after the shutdown exit: %v", ids)
	}
	var row store.ProviderSession
	waitFor(t, 5*time.Second, "session row closed", func() bool {
		rows, err := st.ListProviderSessionsOverlapping(context.Background(),
			time.Now().Add(-time.Hour), time.Now().Add(time.Hour), time.Hour)
		if err != nil {
			t.Fatalf("list provider sessions: %v", err)
		}
		if len(rows) != 1 || rows[0].DisconnectedAt == nil {
			return false
		}
		row = rows[0]
		return true
	})
	if row.DisconnectReason != sessionDisconnectReasonCoordinatorShutdown {
		t.Fatalf("late registration stamped %q, want %q", row.DisconnectReason, sessionDisconnectReasonCoordinatorShutdown)
	}
	// Counted like a socket the close reached: a graceful close, not a drop.
	key := metricKey("ws_disconnects_total", []observation.MetricLabel{{Name: "reason", Value: "peer_close"}})
	if got := srv.observation.Metrics().Snapshot().Counters[key]; got != 1 {
		t.Fatalf("ws_disconnects_total{reason=peer_close} = %d, want 1", got)
	}
}

// A socket the coordinator closed for shutdown reads as going-away, the
// restart-neutral classification, not as a drop.
func TestShutdownCloseStatusIsRestartNeutral(t *testing.T) {
	if got := shutdownCloseStatus(-1, true); got != websocket.StatusGoingAway {
		t.Fatalf("shutdown close must read as going-away: %v", got)
	}
	if got := shutdownCloseStatus(-1, false); got != -1 {
		t.Fatalf("an ordinary drop keeps its status: %v", got)
	}
	if got := shutdownCloseStatus(websocket.StatusNormalClosure, true); got != websocket.StatusNormalClosure {
		t.Fatalf("a peer close keeps its status: %v", got)
	}
	if registry.ClassifyPeerClose(shutdownCloseStatus(-1, true), false) != registry.DisconnectReasonPeerClose {
		t.Fatal("the shutdown close must classify as a peer close")
	}
	// The session row records a coordinator shutdown as such, not as a
	// close frame the peer sent.
	if got := sessionDisconnectReason(websocket.StatusGoingAway, false, readErrorReasonGeneric, true); got != sessionDisconnectReasonCoordinatorShutdown {
		t.Fatalf("shutdown session reason: %s", got)
	}
	if got := sessionDisconnectReason(websocket.StatusGoingAway, false, readErrorReasonGeneric, false); got != "ws_close_1001" {
		t.Fatalf("peer going-away session reason: %s", got)
	}
}
