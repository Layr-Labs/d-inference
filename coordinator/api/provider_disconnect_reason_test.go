package api

// Tests for the provider_sessions disconnect_reason enrichment (2026-07-03
// reconnect-churn analysis): the read loop stamps the observed socket outcome
// (peer close code, read_error, oom_suspected) onto the session row before
// registry.Disconnect's catch-all "disconnect" close lands, so the fleet's
// session history can distinguish graceful closes from silent drops.

import (
	"context"
	"log/slog"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

func TestSessionDisconnectReason(t *testing.T) {
	tests := []struct {
		name         string
		closeStatus  websocket.StatusCode
		oomSuspected bool
		want         string
	}{
		{"normal close frame", websocket.StatusNormalClosure, false, "ws_close_1000"},
		{"going away close frame", websocket.StatusGoingAway, false, "ws_close_1001"},
		{"policy violation (challenge force-reconnect)", websocket.StatusPolicyViolation, false, "ws_close_1008"},
		{"abrupt drop", -1, false, "read_error"},
		{"abrupt drop under memory pressure", -1, true, "oom_suspected"},
		// A close frame never coexists with the OOM classification in the read
		// loop (classification only runs on the abrupt branch), but the mapping
		// must still prioritize the stronger signal if both are ever set.
		{"oom wins over close frame", websocket.StatusNormalClosure, true, "oom_suspected"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := sessionDisconnectReason(tt.closeStatus, tt.oomSuspected); got != tt.want {
				t.Errorf("sessionDisconnectReason(%d, %v) = %q, want %q",
					tt.closeStatus, tt.oomSuspected, got, tt.want)
			}
		})
	}
}

// sessionReasonHarness boots a coordinator, connects one provider WebSocket,
// registers it, and waits until both the registry and the session row see it.
type sessionReasonHarness struct {
	reg  *registry.Registry
	st   *store.MemoryStore
	conn *websocket.Conn
}

func newSessionReasonHarness(t *testing.T, ctx context.Context) *sessionReasonHarness {
	return newSessionReasonHarnessWith(t, ctx, nil)
}

// newSessionReasonHarnessWith optionally wraps the raw memory store before it
// is handed to the server (and, via NewServer, the registry). The harness
// itself keeps reading session rows from the raw store.
func newSessionReasonHarnessWith(t *testing.T, ctx context.Context, wrap func(*registry.Registry, *store.MemoryStore) store.Store) *sessionReasonHarness {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	var serverStore store.Store = st
	if wrap != nil {
		serverStore = wrap(reg, st)
	}
	srv := NewServer(reg, serverStore, ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)

	fixture := newProviderWSFixture(t, ctx, ts.URL, reg, protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			ChipName: "Apple M3 Max",
			MemoryGB: 64,
		},
		Models:  []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
		Backend: "mlx-swift",
	})
	conn := fixture.Conn

	// Registration and OpenProviderSession are async — wait for both so the
	// disconnect under test can never race the session row's creation.
	h := &sessionReasonHarness{reg: reg, st: st, conn: conn}
	awaitTestCondition(t, ctx, "provider registered with open session row", func() bool {
		ps, ok := h.sessionRow(t)
		return ok && ps.DisconnectedAt == nil
	})
	return h
}

// sessionRow returns the single provider session row, if present.
func (h *sessionReasonHarness) sessionRow(t *testing.T) (store.ProviderSession, bool) {
	t.Helper()
	rows, err := h.st.ListProviderSessionsOverlapping(context.Background(),
		time.Now().Add(-time.Hour), time.Now().Add(time.Hour), time.Hour)
	if err != nil {
		t.Fatalf("list provider sessions: %v", err)
	}
	if len(rows) == 0 {
		return store.ProviderSession{}, false
	}
	if len(rows) > 1 {
		t.Fatalf("expected 1 session row, got %d", len(rows))
	}
	return rows[0], true
}

// closedReason polls until the session row is closed and returns its reason.
func (h *sessionReasonHarness) closedReason(t *testing.T) string {
	t.Helper()
	var reason string
	awaitTestCondition(t, context.Background(), "session row closed", func() bool {
		ps, ok := h.sessionRow(t)
		if !ok || ps.DisconnectedAt == nil {
			return false
		}
		reason = ps.DisconnectReason
		return true
	})
	awaitTestCondition(t, context.Background(), "provider removed after session close", func() bool {
		return h.reg.ProviderCount() == 0
	})
	return reason
}


// A peer-initiated clean close must be stamped with its close code, not the
// registry's generic "disconnect".
func TestProviderSessionReasonPeerClose(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	h := newSessionReasonHarness(t, ctx)

	if err := h.conn.Close(websocket.StatusNormalClosure, "done"); err != nil {
		t.Fatalf("client close: %v", err)
	}

	if reason := h.closedReason(t); reason != "ws_close_1000" {
		t.Errorf("disconnect_reason = %q, want %q", reason, "ws_close_1000")
	}
}

// An abrupt TCP-level drop (no close frame — the dominant silent-sleep /
// network-loss signature) must be stamped "read_error".
func TestProviderSessionReasonAbruptClose(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	h := newSessionReasonHarness(t, ctx)

	// CloseNow tears down the TCP connection without a WebSocket close
	// handshake, so the server sees a frame-less read error.
	if err := h.conn.CloseNow(); err != nil {
		t.Fatalf("client close now: %v", err)
	}

	if reason := h.closedReason(t); reason != "read_error" {
		t.Errorf("disconnect_reason = %q, want %q", reason, "read_error")
	}
}

// When the registry disconnects first (stale eviction, duplicate-serial kick),
// the read loop must NOT overwrite the registry's reason: the provider is
// already gone from the registry when the read loop unwinds, so the row keeps
// the registry-owned "disconnect".
func TestProviderSessionReasonRegistryDisconnectWins(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	h := newSessionReasonHarness(t, ctx)
	defer h.conn.CloseNow()

	ids := h.reg.ProviderIDs()
	if len(ids) != 1 {
		t.Fatalf("provider ids = %d, want 1", len(ids))
	}
	// Same public hook the stale-eviction sweep uses: it removes the registry
	// entry, closes the provider writer/socket, and stamps the session.
	h.reg.Disconnect(ids[0])

	// Drain any challenge/trust frames already buffered before observing the
	// server-side teardown. A single Read can succeed on such a frame even
	// though Disconnect has already closed the socket.
	assertSocketClosed(t, h.conn)

	if reason := h.closedReason(t); reason != "disconnect" {
		t.Errorf("disconnect_reason = %q, want %q", reason, "disconnect")
	}
	if ps, ok := h.sessionRow(t); !ok || ps.DisconnectReason != "disconnect" {
		t.Errorf("disconnect_reason after read-loop teardown = %q, want %q", ps.DisconnectReason, "disconnect")
	}
}

// sessionWriteRecord captures the registry's view of a provider at the moment
// a CloseProviderSession write arrived at the store.
type sessionWriteRecord struct {
	reason     string
	inRegistry bool
	status     registry.ProviderStatus
}

// sessionStampRecorder blocks the first read_error session write on an explicit
// release channel, simulating a stalled DB without coupling correctness to time.
type sessionStampRecorder struct {
	store.Store
	reg     *registry.Registry
	entered chan sessionWriteRecord
	release chan struct{}
}

func (r *sessionStampRecorder) CloseProviderSession(ctx context.Context, sessionID, reason string, when time.Time) error {
	rec := sessionWriteRecord{reason: reason}
	if p := r.reg.GetProvider(sessionID); p != nil {
		rec.inRegistry = true
		p.Mu().Lock()
		rec.status = p.Status
		p.Mu().Unlock()
	}
	if reason == "read_error" {
		select {
		case r.entered <- rec:
		case <-ctx.Done():
			return ctx.Err()
		}
		select {
		case <-r.release:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return r.Store.CloseProviderSession(ctx, sessionID, reason, when)
}


// Regression for the PR #512 review finding: when the read loop exits, the
// provider must already be unroutable when the durable disconnect-reason write
// starts — a slow provider_sessions upsert must not leave a dead provider
// selectable by routing for its duration — and the slow write must still win
// first-close over the registry's later generic "disconnect".
func TestProviderUnroutableBeforeSessionStamp(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rec := &sessionStampRecorder{
		entered: make(chan sessionWriteRecord, 1),
		release: make(chan struct{}),
	}
	h := newSessionReasonHarnessWith(t, ctx, func(reg *registry.Registry, st *store.MemoryStore) store.Store {
		rec.reg = reg
		rec.Store = st
		return rec
	})

	if err := h.conn.CloseNow(); err != nil {
		t.Fatalf("client close now: %v", err)
	}

	var stamp sessionWriteRecord
	select {
	case stamp = <-rec.entered:
	case <-ctx.Done():
		t.Fatalf("waiting for read_error session write: %v", ctx.Err())
	}
	// Unroutable means either already removed from the registry, or still
	// present but StatusOffline — which fails every routing-eligibility gate.
	if stamp.inRegistry && stamp.status != registry.StatusOffline {
		t.Errorf("provider status when the session stamp arrived = %q, want %q (dead provider was routable during the durable write)",
			stamp.status, registry.StatusOffline)
	}

	close(rec.release)
	if reason := h.closedReason(t); reason != "read_error" {
		t.Errorf("disconnect_reason = %q, want %q (blocked stamp must win first-close)", reason, "read_error")
	}
}
