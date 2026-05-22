package liveness_test

import (
	"context"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/liveness"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// inspectableStore is an in-memory store wrapper that lets the integration
// test peek at appended heartbeats + session rows without exporting the
// memory store internals. It satisfies store.Store by delegating everything
// to a real *store.MemoryStore, but additionally records heartbeats it sees
// and exposes the latest session row for a provider.
type inspectableStore struct {
	*store.MemoryStore

	mu         sync.Mutex
	heartbeats []store.HeartbeatEvent
	sessions   []sessionRow
}

type sessionRow struct {
	id               int64
	providerID       string
	coordinatorID    string
	connectedAt      time.Time
	disconnectedAt   time.Time
	disconnectReason string
}

func newInspectableStore() *inspectableStore {
	return &inspectableStore{MemoryStore: store.NewMemory("")}
}

func (s *inspectableStore) AppendHeartbeats(ctx context.Context, events []store.HeartbeatEvent) error {
	s.mu.Lock()
	s.heartbeats = append(s.heartbeats, events...)
	s.mu.Unlock()
	return s.MemoryStore.AppendHeartbeats(ctx, events)
}

func (s *inspectableStore) OpenSession(ctx context.Context, sess store.SessionStart) (int64, error) {
	id, err := s.MemoryStore.OpenSession(ctx, sess)
	if err != nil {
		return 0, err
	}
	s.mu.Lock()
	s.sessions = append(s.sessions, sessionRow{
		id:            id,
		providerID:    sess.ProviderID,
		coordinatorID: sess.CoordinatorID,
		connectedAt:   sess.ConnectedAt,
	})
	s.mu.Unlock()
	return id, nil
}

func (s *inspectableStore) CloseSession(ctx context.Context, sessionID int64, reason string, at time.Time, lastHeartbeat time.Time, reqs, toks int64) error {
	s.mu.Lock()
	for i := range s.sessions {
		if s.sessions[i].id == sessionID && s.sessions[i].disconnectedAt.IsZero() {
			s.sessions[i].disconnectedAt = at
			s.sessions[i].disconnectReason = reason
			break
		}
	}
	s.mu.Unlock()
	return s.MemoryStore.CloseSession(ctx, sessionID, reason, at, lastHeartbeat, reqs, toks)
}

func (s *inspectableStore) CloseOrphanSessions(ctx context.Context, reason string, at time.Time, coordinatorID string) (int64, error) {
	s.mu.Lock()
	for i := range s.sessions {
		if !s.sessions[i].disconnectedAt.IsZero() {
			continue
		}
		if coordinatorID != "" && s.sessions[i].coordinatorID != coordinatorID {
			continue
		}
		s.sessions[i].disconnectedAt = at
		s.sessions[i].disconnectReason = reason
	}
	s.mu.Unlock()
	return s.MemoryStore.CloseOrphanSessions(ctx, reason, at, coordinatorID)
}

func (s *inspectableStore) latestSession(providerID string) sessionRow {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := len(s.sessions) - 1; i >= 0; i-- {
		if s.sessions[i].providerID == providerID {
			return s.sessions[i]
		}
	}
	return sessionRow{}
}

func (s *inspectableStore) heartbeatCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.heartbeats)
}

// quietLog returns a logger that swallows everything below error level so
// the test output stays readable.
func quietLog() *slog.Logger {
	return slog.New(slog.NewTextHandler(devNull{}, &slog.HandlerOptions{Level: slog.LevelError}))
}

type devNull struct{}

func (devNull) Write(p []byte) (int, error) { return len(p), nil }

// waitFor polls until predicate returns true or the deadline elapses.
func waitFor(t *testing.T, predicate func() bool, deadline time.Duration, msg string) {
	t.Helper()
	end := time.Now().Add(deadline)
	for time.Now().Before(end) {
		if predicate() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !predicate() {
		t.Fatalf("timed out waiting: %s", msg)
	}
}

// End-to-end test: the registry's Heartbeat path emits heartbeats that the
// writer flushes into the store. The session lifecycle (Register / clean
// disconnect / stale eviction) writes the right disconnect reasons.
func TestLivenessFullCycle(t *testing.T) {
	st := newInspectableStore()
	logger := quietLog()

	w := liveness.NewWriter(st, logger, nil, liveness.Config{
		BufferSize:    32,
		BatchSize:     2,
		FlushInterval: 50 * time.Millisecond,
		DrainTimeout:  2 * time.Second,
	})
	w.Start()
	defer w.Close()

	tracker := liveness.NewSessionTracker(st, logger, "coord-test")
	sink := liveness.NewSink(w, tracker)

	reg := registry.New(logger)
	reg.SetStore(st)
	reg.SetLivenessSink(sink)

	t.Run("Register opens a session", func(t *testing.T) {
		reg.Register("prov-A", nil, &protocol.RegisterMessage{
			Hardware: protocol.Hardware{ChipName: "M4 Max", MemoryGB: 64},
			Backend:  "vllm-mlx",
		})

		waitFor(t, func() bool {
			row := st.latestSession("prov-A")
			return row.id != 0 && row.disconnectedAt.IsZero()
		}, time.Second, "prov-A session not opened")
	})

	t.Run("Heartbeat is recorded", func(t *testing.T) {
		active := "qwen3.5"
		reg.Heartbeat("prov-A", &protocol.HeartbeatMessage{
			Status:      "idle",
			ActiveModel: &active,
			SystemMetrics: protocol.SystemMetrics{
				MemoryPressure: 0.4,
				CPUUsage:       0.1,
				ThermalState:   "nominal",
			},
		})

		waitFor(t, func() bool {
			return st.heartbeatCount() >= 1
		}, time.Second, "no heartbeats appended")
	})

	t.Run("RecordDisconnect(clean) closes the session with reason", func(t *testing.T) {
		reg.RecordDisconnect("prov-A", store.DisconnectReasonCleanClose)

		// SessionTracker.Close is synchronous against the store, no wait needed.
		row := st.latestSession("prov-A")
		if row.disconnectedAt.IsZero() {
			t.Fatalf("expected session closed, got open row: %+v", row)
		}
		if row.disconnectReason != store.DisconnectReasonCleanClose {
			t.Fatalf("expected reason %q, got %q", store.DisconnectReasonCleanClose, row.disconnectReason)
		}
	})

	t.Run("evictStale closes session with stale_heartbeat reason", func(t *testing.T) {
		reg.Register("prov-B", nil, &protocol.RegisterMessage{
			Hardware: protocol.Hardware{ChipName: "M3", MemoryGB: 32},
			Backend:  "vllm-mlx",
		})
		// Let prov-B's LastHeartbeat age past the staleness threshold below.
		time.Sleep(30 * time.Millisecond)
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		reg.StartEvictionLoop(ctx, 5*time.Millisecond)

		waitFor(t, func() bool {
			row := st.latestSession("prov-B")
			return !row.disconnectedAt.IsZero() &&
				row.disconnectReason == store.DisconnectReasonStaleHeartbeat
		}, 2*time.Second, "prov-B not evicted with stale_heartbeat reason")
	})
}

// CloseOrphans on coordinator boot stamps "coordinator_restart" on sessions
// left open by THIS coordinator's prior incarnation (same coordinatorID).
// Sessions owned by a sibling coordinator are left alone — important for
// blue-green deploys where two coordinator processes run concurrently.
func TestOrphanCloseOnBoot(t *testing.T) {
	st := newInspectableStore()
	logger := quietLog()

	// Previous incarnation of "coord-A" opens two sessions, then "crashes"
	// (we discard the tracker without closing anything).
	prev := liveness.NewSessionTracker(st, logger, "coord-A")
	prev.Open("ghost-A1")
	prev.Open("ghost-A2")

	// A sibling coordinator "coord-B" runs concurrently and has its own
	// live session. CloseOrphans on coord-A's boot must NOT touch this.
	siblingTracker := liveness.NewSessionTracker(st, logger, "coord-B")
	siblingTracker.Open("live-on-B")

	// New incarnation of "coord-A" boots and sweeps.
	bootTracker := liveness.NewSessionTracker(st, logger, "coord-A")
	closed, err := bootTracker.CloseOrphans(context.Background())
	if err != nil {
		t.Fatalf("CloseOrphans: %v", err)
	}
	if closed != 2 {
		t.Fatalf("expected exactly 2 orphans closed (only coord-A's), got %d", closed)
	}

	// coord-A's ghosts should now be stamped coordinator_restart.
	for _, id := range []string{"ghost-A1", "ghost-A2"} {
		row := st.latestSession(id)
		if row.disconnectedAt.IsZero() {
			t.Fatalf("expected %s closed", id)
		}
		if !strings.Contains(row.disconnectReason, "coordinator_restart") {
			t.Fatalf("expected %s reason=coordinator_restart, got %q", id, row.disconnectReason)
		}
	}

	// coord-B's session must still be open — it's still live there.
	siblingRow := st.latestSession("live-on-B")
	if !siblingRow.disconnectedAt.IsZero() {
		t.Fatalf("expected live-on-B still open, got closed with reason %q", siblingRow.disconnectReason)
	}
}
