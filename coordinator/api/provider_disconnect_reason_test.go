package api

// Tests for the provider_sessions disconnect_reason enrichment (2026-07-03
// reconnect-churn analysis): the read loop stamps the observed socket outcome
// (peer close code, read_error, oom_suspected) onto the session row before
// registry.Disconnect's catch-all "disconnect" close lands, so the fleet's
// session history can distinguish graceful closes from silent drops.

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
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
		readReason   string
		want         string
	}{
		{"normal close frame", websocket.StatusNormalClosure, false, readErrorReasonGeneric, "ws_close_1000"},
		{"going away close frame", websocket.StatusGoingAway, false, readErrorReasonGeneric, "ws_close_1001"},
		{"policy violation (challenge force-reconnect)", websocket.StatusPolicyViolation, false, readErrorReasonGeneric, "ws_close_1008"},
		{"abrupt drop", -1, false, readErrorReasonGeneric, "read_error"},
		{"control-frame handling failure", -1, false, readErrorReasonControlFrame, "read_error_control_frame"},
		{"abrupt drop under memory pressure", -1, true, readErrorReasonGeneric, "oom_suspected"},
		// A close frame never coexists with the OOM classification in the read
		// loop (classification only runs on the abrupt branch), but the mapping
		// must still prioritize the stronger signal if both are ever set.
		{"oom wins over close frame", websocket.StatusNormalClosure, true, readErrorReasonGeneric, "oom_suspected"},
		// Likewise the read-error classification only exists on the frame-less
		// branch; a close code must win if both are ever set.
		{"close code wins over control-frame reason", websocket.StatusNormalClosure, false, readErrorReasonControlFrame, "ws_close_1000"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := sessionDisconnectReason(tt.closeStatus, tt.oomSuspected, tt.readReason); got != tt.want {
				t.Errorf("sessionDisconnectReason(%d, %v, %q) = %q, want %q",
					tt.closeStatus, tt.oomSuspected, tt.readReason, got, tt.want)
			}
		})
	}
}

// TestReadErrorDisconnectReason pins the frame-less read-error classification.
// The first case is the exact chain nhooyr produces when a pong cannot take
// the write lock while a data frame is in flight (observed live in
// registry.TestUnfragmentedConnWriteStallsPeerPing); anything not about a
// control frame stays the generic "read_error".
func TestReadErrorDisconnectReason(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want string
	}{
		{"pong blocked behind an in-flight data frame",
			errors.New("failed to get reader: failed to handle control frame opPing: failed to write control frame opPong: failed to acquire lock: context deadline exceeded"),
			readErrorReasonControlFrame},
		{"pong write stalled on a full socket",
			errors.New("failed to get reader: failed to handle control frame opPing: failed to write control frame opPong: failed to write frame: context deadline exceeded"),
			readErrorReasonControlFrame},
		{"malformed control frame",
			errors.New("failed to get reader: failed to handle control frame opPing: received fragmented control frame"),
			readErrorReasonControlFrame},
		{"tcp reset",
			errors.New("failed to get reader: failed to read frame header: read tcp 127.0.0.1:1->127.0.0.1:2: read: connection reset by peer"),
			readErrorReasonGeneric},
		{"eof", io.EOF, readErrorReasonGeneric},
		{"nil", nil, readErrorReasonGeneric},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := readErrorDisconnectReason(tt.err); got != tt.want {
				t.Errorf("readErrorDisconnectReason(%v) = %q, want %q", tt.err, got, tt.want)
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
	return newSessionReasonHarnessDial(t, ctx, wrap, nil)
}

// newSessionReasonHarnessDial additionally lets the test control how the
// provider WebSocket is dialed (e.g. to capture the underlying net.Conn).
func newSessionReasonHarnessDial(t *testing.T, ctx context.Context, wrap func(*registry.Registry, *store.MemoryStore) store.Store, dialOpts *websocket.DialOptions) *sessionReasonHarness {
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

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, dialOpts)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}

	regMsg := protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			ChipName: "Apple M3 Max",
			MemoryGB: 64,
		},
		Models:  []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
		Backend: "mlx-swift",
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}

	// Registration and OpenProviderSession are async — wait for both so the
	// disconnect under test can never race the session row's creation.
	h := &sessionReasonHarness{reg: reg, st: st, conn: conn}
	waitFor(t, 5*time.Second, "provider registered with open session row", func() bool {
		if reg.ProviderCount() != 1 {
			return false
		}
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
	waitFor(t, 5*time.Second, "session row closed", func() bool {
		ps, ok := h.sessionRow(t)
		if !ok || ps.DisconnectedAt == nil {
			return false
		}
		reason = ps.DisconnectReason
		return true
	})
	return reason
}

func waitFor(t *testing.T, timeout time.Duration, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
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

// A read-loop exit caused by a control-frame handling failure must be stamped
// "read_error_control_frame" through the real HTTP path, not the generic
// "read_error". The trigger here is a protocol violation (a FIN=0 ping) rather
// than the production write stall — that stall is reproduced live in
// registry.TestUnfragmentedConnWriteStallsPeerPing — because it
// deterministically yields the same "failed to handle control frame" read
// error the classifier keys on, without a multi-second socket stall.
func TestProviderSessionReasonControlFrameReadError(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rawConnCh := make(chan net.Conn, 1)
	h := newSessionReasonHarnessDial(t, ctx, nil, &websocket.DialOptions{
		HTTPClient: &http.Client{Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				c, err := (&net.Dialer{}).DialContext(ctx, network, addr)
				if err != nil {
					return nil, err
				}
				rawConnCh <- c
				return c, nil
			},
		}},
	})
	var rawConn net.Conn
	select {
	case rawConn = <-rawConnCh:
	default:
		t.Fatal("dial did not capture the underlying net.Conn")
	}
	defer h.conn.CloseNow()

	// A masked, zero-length ping with FIN clear, written underneath the idle
	// nhooyr client. nhooyr's handleControl rejects it ("received fragmented
	// control frame") and readLoop wraps it as "failed to handle control frame
	// opPing: ..." — a frame-less Read failure on the coordinator side.
	if _, err := rawConn.Write([]byte{0x09, 0x80, 0x11, 0x22, 0x33, 0x44}); err != nil {
		t.Fatalf("write fragmented ping: %v", err)
	}

	if reason := h.closedReason(t); reason != "read_error_control_frame" {
		t.Errorf("disconnect_reason = %q, want %q", reason, "read_error_control_frame")
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
	// Same call the stale-eviction sweep makes.
	h.reg.Disconnect(ids[0])

	if reason := h.closedReason(t); reason != "disconnect" {
		t.Errorf("disconnect_reason = %q, want %q", reason, "disconnect")
	}

	// The read loop's own teardown (unblocked by the registry's socket close)
	// must not flip the reason afterwards. Disconnect is synchronous from the
	// registry map's perspective, so any overwrite would land within the poll
	// window below.
	time.Sleep(300 * time.Millisecond)
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

// sessionStampRecorder wraps the store and, on every CloseProviderSession,
// records whether the session's provider was still in the registry and its
// status, then holds the write for delay before delegating — simulating a
// slow/stalled DB on the durable disconnect-reason path.
type sessionStampRecorder struct {
	store.Store
	reg    *registry.Registry
	delay  time.Duration
	mu     sync.Mutex
	writes []sessionWriteRecord
}

func (r *sessionStampRecorder) CloseProviderSession(ctx context.Context, sessionID, reason string, when time.Time) error {
	rec := sessionWriteRecord{reason: reason}
	if p := r.reg.GetProvider(sessionID); p != nil {
		rec.inRegistry = true
		p.Mu().Lock()
		rec.status = p.Status
		p.Mu().Unlock()
	}
	r.mu.Lock()
	r.writes = append(r.writes, rec)
	r.mu.Unlock()
	if r.delay > 0 {
		time.Sleep(r.delay)
	}
	return r.Store.CloseProviderSession(ctx, sessionID, reason, when)
}

func (r *sessionStampRecorder) firstWrite(reason string) (sessionWriteRecord, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, w := range r.writes {
		if w.reason == reason {
			return w, true
		}
	}
	return sessionWriteRecord{}, false
}

// After the teardown reorder the disconnect path writes the session row
// exactly ONCE, carrying the specific reason. Before it, the read loop wrote a
// synchronous 3 s-bounded stamp and registry.Disconnect a second, generic
// async close (a no-op under first-close-wins, but a DB round trip per
// disconnect — and the first one sat on the teardown path ahead of the
// pending flush).
func TestProviderSessionCloseWrittenOnceWithReason(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rec := &sessionStampRecorder{}
	h := newSessionReasonHarnessWith(t, ctx, func(reg *registry.Registry, st *store.MemoryStore) store.Store {
		rec.reg = reg
		rec.Store = st
		return rec
	})

	if err := h.conn.Close(websocket.StatusGoingAway, "restarting"); err != nil {
		t.Fatalf("client close: %v", err)
	}
	if reason := h.closedReason(t); reason != "ws_close_1001" {
		t.Errorf("disconnect_reason = %q, want %q", reason, "ws_close_1001")
	}
	// A second (generic) write would land within the registry's async close
	// window; give it every chance to show up.
	time.Sleep(300 * time.Millisecond)
	rec.mu.Lock()
	writes := append([]sessionWriteRecord(nil), rec.writes...)
	rec.mu.Unlock()
	if len(writes) != 1 {
		t.Fatalf("CloseProviderSession writes per disconnect = %d (%+v), want exactly 1", len(writes), writes)
	}
	if writes[0].reason != "ws_close_1001" {
		t.Errorf("the single session close carried reason %q, want ws_close_1001", writes[0].reason)
	}
	if writes[0].inRegistry {
		t.Errorf("session close reached the store while the provider was still in the registry")
	}
}

// Regression for the PR #512 review finding: when the read loop exits, the
// provider must already be unroutable when the durable disconnect-reason write
// starts — a slow provider_sessions upsert must not leave a dead provider
// selectable by routing for its duration — and the slow write must still win
// first-close over the registry's later generic "disconnect".
func TestProviderUnroutableBeforeSessionStamp(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rec := &sessionStampRecorder{delay: 300 * time.Millisecond}
	h := newSessionReasonHarnessWith(t, ctx, func(reg *registry.Registry, st *store.MemoryStore) store.Store {
		rec.reg = reg
		rec.Store = st
		return rec
	})

	if err := h.conn.CloseNow(); err != nil {
		t.Fatalf("client close now: %v", err)
	}

	if reason := h.closedReason(t); reason != "read_error" {
		t.Errorf("disconnect_reason = %q, want %q (delayed stamp must still win first-close)", reason, "read_error")
	}

	stamp, ok := rec.firstWrite("read_error")
	if !ok {
		t.Fatal("no read_error session write reached the store")
	}
	// Unroutable means either already removed from the registry, or still
	// present but StatusOffline — which fails every routing-eligibility gate.
	if stamp.inRegistry && stamp.status != registry.StatusOffline {
		t.Errorf("provider status when the session stamp arrived = %q, want %q (dead provider was routable during the durable write)",
			stamp.status, registry.StatusOffline)
	}
}
