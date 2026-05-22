package store

import (
	"context"
	"encoding/json"
	"testing"
	"time"
)

// runLivenessSuite exercises the liveness methods against an arbitrary Store
// implementation. Called once per backend (memory + postgres) so both stay
// in sync. Per CLAUDE.md: prefer live-isolated over mocks — we instantiate
// each backend directly.
func runLivenessSuite(t *testing.T, s Store) {
	t.Helper()
	ctx := context.Background()
	provider := "prov-test"

	t.Run("AppendHeartbeats empty is a noop", func(t *testing.T) {
		if err := s.AppendHeartbeats(ctx, nil); err != nil {
			t.Fatalf("AppendHeartbeats nil: %v", err)
		}
	})

	t.Run("AppendHeartbeats writes rows", func(t *testing.T) {
		now := time.Now().Truncate(time.Microsecond)
		mp := float32(0.42)
		gpu := float32(8.5)
		events := []HeartbeatEvent{
			{
				ProviderID:        provider,
				At:                now,
				Status:            "idle",
				MemoryPressure:    0.4,
				CPUUsage:          0.2,
				ThermalState:      "nominal",
				MemoryAvailableGB: &mp, // arbitrary nullable
				GPUMemoryActiveGB: &gpu,
				BackendState:      "running",
				ActiveModel:       "qwen3.5-27b",
				Capacity:          json.RawMessage(`{"slots":[]}`),
			},
			{
				ProviderID:     provider,
				At:             now.Add(5 * time.Second),
				Status:         "serving",
				MemoryPressure: 0.6,
				CPUUsage:       0.3,
				ThermalState:   "fair",
				BackendState:   "running",
				ActiveModel:    "qwen3.5-27b",
			},
		}
		if err := s.AppendHeartbeats(ctx, events); err != nil {
			t.Fatalf("AppendHeartbeats: %v", err)
		}
	})

	t.Run("OpenSession returns id, CloseSession is idempotent", func(t *testing.T) {
		start := time.Now()
		id, err := s.OpenSession(ctx, SessionStart{
			ProviderID:    provider,
			ConnectedAt:   start,
			CoordinatorID: "coord-A",
		})
		if err != nil {
			t.Fatalf("OpenSession: %v", err)
		}
		if id == 0 {
			t.Fatalf("expected non-zero session id, got 0")
		}

		// Close once with reason.
		closedAt := start.Add(30 * time.Second)
		lastHB := start.Add(25 * time.Second)
		if err := s.CloseSession(ctx, id, DisconnectReasonCleanClose, closedAt, lastHB, 7, 1234); err != nil {
			t.Fatalf("CloseSession: %v", err)
		}

		// Closing again must NOT error (idempotent) but also must not flip the
		// reason — the WHERE clause requires disconnected_at IS NULL.
		if err := s.CloseSession(ctx, id, DisconnectReasonReadError, closedAt.Add(time.Second), lastHB, 99, 99999); err != nil {
			t.Fatalf("CloseSession second call: %v", err)
		}
	})

	t.Run("CloseOrphanSessions only touches open rows", func(t *testing.T) {
		// Open three sessions; close one cleanly; orphan-close the rest.
		id1, err := s.OpenSession(ctx, SessionStart{ProviderID: "orphan-A", ConnectedAt: time.Now(), CoordinatorID: "coord-A"})
		if err != nil {
			t.Fatalf("OpenSession A: %v", err)
		}
		_, err = s.OpenSession(ctx, SessionStart{ProviderID: "orphan-B", ConnectedAt: time.Now(), CoordinatorID: "coord-A"})
		if err != nil {
			t.Fatalf("OpenSession B: %v", err)
		}
		_, err = s.OpenSession(ctx, SessionStart{ProviderID: "orphan-C", ConnectedAt: time.Now(), CoordinatorID: "coord-A"})
		if err != nil {
			t.Fatalf("OpenSession C: %v", err)
		}

		// Cleanly close A so orphan-sweep should NOT touch it.
		closedAt := time.Now()
		if err := s.CloseSession(ctx, id1, DisconnectReasonCleanClose, closedAt, time.Time{}, 0, 0); err != nil {
			t.Fatalf("CloseSession A: %v", err)
		}

		closed, err := s.CloseOrphanSessions(ctx, DisconnectReasonCoordinatorRestart, time.Now(), "coord-A")
		if err != nil {
			t.Fatalf("CloseOrphanSessions: %v", err)
		}
		if closed < 2 {
			t.Fatalf("expected ≥2 orphan sessions closed, got %d", closed)
		}

		// Running again should be a no-op (all already closed).
		closed2, err := s.CloseOrphanSessions(ctx, DisconnectReasonCoordinatorRestart, time.Now(), "coord-A")
		if err != nil {
			t.Fatalf("CloseOrphanSessions second call: %v", err)
		}
		if closed2 != 0 {
			t.Fatalf("expected 0 on re-run, got %d", closed2)
		}
	})

	t.Run("DeleteHeartbeatsBefore respects limit and cutoff", func(t *testing.T) {
		// Insert 5 old + 3 fresh.
		base := time.Now().Add(-48 * time.Hour)
		old := make([]HeartbeatEvent, 5)
		for i := range old {
			old[i] = HeartbeatEvent{
				ProviderID:   "retention",
				At:           base.Add(time.Duration(i) * time.Minute),
				Status:       "idle",
				ThermalState: "nominal",
			}
		}
		fresh := []HeartbeatEvent{
			{ProviderID: "retention", At: time.Now(), Status: "idle", ThermalState: "nominal"},
			{ProviderID: "retention", At: time.Now().Add(-time.Minute), Status: "idle", ThermalState: "nominal"},
			{ProviderID: "retention", At: time.Now().Add(-2 * time.Minute), Status: "idle", ThermalState: "nominal"},
		}
		if err := s.AppendHeartbeats(ctx, append(old, fresh...)); err != nil {
			t.Fatalf("AppendHeartbeats: %v", err)
		}

		// Cut off 24h ago, batch-limit 3 → expect 3 deleted on first call,
		// then 2 remaining old, then 0 once drained.
		cutoff := time.Now().Add(-24 * time.Hour)
		deleted, err := s.DeleteHeartbeatsBefore(ctx, cutoff, 3)
		if err != nil {
			t.Fatalf("DeleteHeartbeatsBefore: %v", err)
		}
		if deleted != 3 {
			t.Fatalf("first call: expected 3 deleted, got %d", deleted)
		}

		deleted, err = s.DeleteHeartbeatsBefore(ctx, cutoff, 100)
		if err != nil {
			t.Fatalf("DeleteHeartbeatsBefore drain: %v", err)
		}
		if deleted != 2 {
			t.Fatalf("drain call: expected 2 deleted, got %d", deleted)
		}

		deleted, err = s.DeleteHeartbeatsBefore(ctx, cutoff, 100)
		if err != nil {
			t.Fatalf("DeleteHeartbeatsBefore empty: %v", err)
		}
		if deleted != 0 {
			t.Fatalf("empty call: expected 0 deleted, got %d", deleted)
		}
	})

	t.Run("DeleteHeartbeatsBefore with non-positive limit is a noop", func(t *testing.T) {
		deleted, err := s.DeleteHeartbeatsBefore(ctx, time.Now(), 0)
		if err != nil {
			t.Fatalf("DeleteHeartbeatsBefore(0): %v", err)
		}
		if deleted != 0 {
			t.Fatalf("expected 0 deleted with limit=0, got %d", deleted)
		}
	})
}

// TestMemoryLiveness exercises the in-memory backend.
func TestMemoryLiveness(t *testing.T) {
	s := NewMemory("")
	runLivenessSuite(t, s)
}

// TestPostgresLiveness exercises the Postgres backend. Skipped without
// DATABASE_URL (mirrors the convention in postgres_test.go).
func TestPostgresLiveness(t *testing.T) {
	s := testPostgresStore(t)
	runLivenessSuite(t, s)
}
