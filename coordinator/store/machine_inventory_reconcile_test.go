package store

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"testing"
	"time"
)

type inventorySessionSnapshot struct {
	identity, account string
	closed            bool
	closedAt          *time.Time
	observation       MachineObservation
}

func readInventorySession(t *testing.T, st Store, id string) inventorySessionSnapshot {
	t.Helper()
	var r inventorySessionSnapshot
	switch s := st.(type) {
	case *MemoryStore:
		s.mu.Lock()
		defer s.mu.Unlock()
		r.identity = s.machineInventory.sessionMachines[id]
		r.observation = s.machineInventory.sessions[id]
		r.account = r.observation.AccountID
		r.closed = r.observation.Disconnected
	case *PostgresStore:
		var raw []byte
		if err := s.pool.QueryRow(context.Background(), `SELECT machine_id,account_id,disconnected_at,observation FROM darkbloom_machine_sessions WHERE session_id=$1`, id).Scan(&r.identity, &r.account, &r.closedAt, &raw); err != nil {
			t.Fatal(err)
		}
		r.closed = r.closedAt != nil
		if err := json.Unmarshal(raw, &r.observation); err != nil {
			t.Fatal(err)
		}
	}
	return r
}

func TestMachineInventoryReconcileClosesOrphansAndPreservesLiveSessions(t *testing.T) {
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			inventory, _ := As[MachineInventoryStore](st)
			// Production discovers this capability through the cache decorator.
			reconciler, ok := As[MachineInventoryReconcileStore](NewCached(st, DefaultCacheConfig()))
			if !ok {
				t.Fatal("reconciler unavailable through cached store")
			}
			now := time.Now().UTC().Truncate(time.Millisecond)
			old := now.Add(-10 * time.Minute)
			seed := func(id string, seen, heartbeat time.Time, provider bool) {
				t.Helper()
				if _, err := inventory.ObserveMachine(ctx, MachineObservation{SessionID: id, AccountID: "owner", SEKey: id, At: seen, OSMajor: 27}); err != nil {
					t.Fatal(err)
				}
				if provider {
					if err := st.OpenProviderSession(ctx, id, "", "owner"); err != nil {
						t.Fatal(err)
					}
					if err := st.TouchProviderSession(ctx, id, "", "owner", "", heartbeat); err != nil {
						t.Fatal(err)
					}
				}
			}
			seed("lost-close", old, old, true)
			closedAt := old.Add(2 * time.Minute)
			if err := st.CloseProviderSession(ctx, "lost-close", "disconnect", closedAt); err != nil {
				t.Fatal(err)
			}
			seed("restart", old, old.Add(time.Minute), true)
			seed("missing-provider-row", old, old, false)
			seed("fresh-provider", old, now, true)
			seed("fresh-inventory", now, old, true)
			original := readInventorySession(t, st, "restart")
			for i, want := range []int{2, 1, 0} {
				if n, err := reconciler.ReconcileMachineInventory(ctx, now.Add(-5*time.Minute), 2); err != nil || n != want {
					t.Fatalf("batch %d: count=%d err=%v", i, n, err)
				}
			}
			for _, id := range []string{"lost-close", "restart", "missing-provider-row"} {
				if r := readInventorySession(t, st, id); !r.closed || !r.observation.Disconnected || r.account != "owner" {
					t.Fatalf("orphan not closed without losing attribution: %s %+v", id, r)
				}
			}
			if r := readInventorySession(t, st, "lost-close"); r.observation.DisconnectReason != "provider_session" || r.closedAt != nil && !r.closedAt.Equal(closedAt) {
				t.Fatal("confirmed disconnect was not preserved")
			}
			for _, id := range []string{"fresh-provider", "fresh-inventory"} {
				if readInventorySession(t, st, id).closed {
					t.Fatalf("live session closed: %s", id)
				}
			}
			// Only inferred closure may recover when fresh observations resume.
			live := MachineObservation{SessionID: "restart", AccountID: "owner", SEKey: "restart", At: now, OSMajor: 27}
			if _, err := inventory.ObserveMachine(ctx, live); err != nil {
				t.Fatal(err)
			}
			if r := readInventorySession(t, st, "restart"); r.closed || r.identity != original.identity {
				t.Fatal("fresh observation did not recover the same identity")
			}
			late := live
			late.At = old
			late.Disconnected = true
			if _, err := inventory.ObserveMachine(ctx, late); err != nil {
				t.Fatal(err)
			}
			if readInventorySession(t, st, "restart").closed {
				t.Fatal("late terminal capture overwrote newer liveness")
			}
			live.SessionID = "lost-close"
			live.SEKey = "lost-close"
			if _, err := inventory.ObserveMachine(ctx, live); err != nil {
				t.Fatal(err)
			}
			if !readInventorySession(t, st, "lost-close").closed {
				t.Fatal("late capture reopened a confirmed disconnect")
			}
		})
	}
}

func TestMachineInventoryReconcileRecoversFailedTerminalWriteAfterRestartPostgres(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	old := time.Now().UTC().Add(-10 * time.Minute)
	o := MachineObservation{SessionID: "lost", AccountID: "owner", At: old}
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
	if readInventorySession(t, s, "lost").closed {
		t.Fatal("failed terminal write unexpectedly persisted")
	}
	if err = blocker.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	// No volatile retry queue survives this new store instance.
	restarted, err := NewPostgres(ctx, Config{DatabaseURL: os.Getenv("DATABASE_URL")})
	if err != nil {
		t.Fatal(err)
	}
	defer restarted.Close()
	if n, err := restarted.ReconcileMachineInventory(ctx, time.Now().Add(-5*time.Minute), 100); err != nil || n != 1 {
		t.Fatalf("restart repair: %d %v", n, err)
	}
	if !readInventorySession(t, restarted, "lost").closed {
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
	if _, err := s.ObserveMachine(ctx, MachineObservation{SessionID: "locked", At: time.Now().Add(-10 * time.Minute)}); err != nil {
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
