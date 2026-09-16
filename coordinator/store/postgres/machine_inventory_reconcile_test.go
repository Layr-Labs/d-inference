package postgres

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/inventorytest"
)

func readInventorySession(t *testing.T, st contracts.Store, id string) inventorytest.InventorySessionSnapshot {
	t.Helper()
	var r inventorytest.InventorySessionSnapshot
	switch s := st.(type) {
	case *Store:
		var raw []byte
		if err := s.pool.QueryRow(context.Background(), `SELECT machine_id,account_id,disconnected_at,observation FROM darkbloom_machine_sessions WHERE session_id=$1`, id).Scan(&r.Identity, &r.Account, &r.ClosedAt, &raw); err != nil {
			t.Fatal(err)
		}
		r.Closed = r.ClosedAt != nil
		if err := json.Unmarshal(raw, &r.Observation); err != nil {
			t.Fatal(err)
		}
	}
	return r
}

func TestMachineInventoryReconcileClosesOrphansAndPreservesLiveSessions(t *testing.T) {
	inventorytest.CheckMachineInventoryReconcile(t, testPostgresStore(t), readInventorySession)
}

func TestMachineInventoryReconcileRecoversFailedTerminalWriteAfterRestartPostgres(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	old := time.Now().UTC().Add(-10 * time.Minute)
	o := contracts.MachineObservation{SessionID: "lost", AccountID: "owner", At: old}
	if _, err := s.ObserveMachine(ctx, o); err != nil {
		t.Fatal(err)
	}
	if err := s.CloseProviderSession(ctx, o.SessionID, "disconnect", old.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	blocker, err := s.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer blocker.Rollback(ctx)
	if _, err = blocker.Exec(ctx, `SELECT pg_advisory_xact_lock(9952701)`); err != nil {
		t.Fatal(err)
	}
	o.Disconnected = true
	timeout, cancel := context.WithTimeout(ctx, 25*time.Millisecond)
	_, err = s.ObserveMachine(timeout, o)
	cancel()
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("terminal write was not blocked: %v", err)
	}
	if readInventorySession(t, s, "lost").Closed {
		t.Fatal("failed terminal write unexpectedly persisted")
	}
	if err = blocker.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	// No volatile retry queue survives this new store instance.
	restarted, err := New(ctx, contracts.Config{DatabaseURL: os.Getenv("DATABASE_URL")})
	if err != nil {
		t.Fatal(err)
	}
	defer restarted.Close()
	if n, err := restarted.ReconcileMachineInventory(ctx, time.Now().Add(-5*time.Minute), 100); err != nil || n != 1 {
		t.Fatalf("restart repair: %d %v", n, err)
	}
	if !readInventorySession(t, restarted, "lost").Closed {
		t.Fatal("lost terminal capture was not repaired")
	}
	var observations int
	if err = restarted.pool.QueryRow(ctx, `SELECT COUNT(*) FROM darkbloom_machine_observations WHERE session_id='lost' AND observation->>'disconnect_reason'='provider_session'`).Scan(&observations); err != nil || observations != 1 {
		t.Fatalf("missing repair history: %d %v", observations, err)
	}
}

func TestMachineInventoryReconcileSkipsLockedRowsPostgres(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	if _, err := s.ObserveMachine(ctx, contracts.MachineObservation{SessionID: "locked", At: time.Now().Add(-10 * time.Minute)}); err != nil {
		t.Fatal(err)
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, `SELECT session_id FROM darkbloom_machine_sessions WHERE session_id='locked' FOR UPDATE`); err != nil {
		t.Fatal(err)
	}
	deadline, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	if n, err := s.ReconcileMachineInventory(deadline, time.Now().Add(-5*time.Minute), 100); err != nil || n != 0 {
		t.Fatalf("blocked on busy row: %d %v", n, err)
	}
	if err = tx.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	if n, err := s.ReconcileMachineInventory(deadline, time.Now().Add(-5*time.Minute), 100); err != nil || n != 1 {
		t.Fatalf("skipped row lost: %d %v", n, err)
	}
}
