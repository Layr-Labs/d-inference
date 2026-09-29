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
	// No new provider socket is accepted behind the final flush.
	_, resp, err := websocket.Dial(ctx, wsURL, nil)
	if err == nil || resp == nil || resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("new provider socket must be refused with 503: err=%v resp=%v", err, resp)
	}
	if reg.ProviderIDs() != nil && len(reg.ProviderIDs()) != 0 {
		t.Fatalf("refused socket registered a provider: %v", reg.ProviderIDs())
	}
}
