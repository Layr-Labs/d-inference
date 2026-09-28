package store

import (
	"context"
	"fmt"
	"testing"
	"time"
)

// Pause a real ObserveMachine merge after it acquires the inventory barrier.
// Admissions using the old and surviving IDs must wait, then share one budget.
func TestAppAttestRotationAdmissionWaitsForMachineMerge(t *testing.T) {
	s := testPostgresStore(t)
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	now := time.Now().UTC()
	account, serial := uniqueID("account"), uniqueID("serial")
	observe := func(session, se, verifiedSerial string) MachineObservation {
		return MachineObservation{SessionID: session, AccountID: account, SEKey: se,
			VerifiedSerial: verifiedSerial, At: now, OSMajor: 27, Source: "live_registration"}
	}
	a, err := s.ObserveMachine(ctx, observe(uniqueID("session"), uniqueID("se"), serial))
	if err != nil {
		t.Fatal(err)
	}
	second := observe(uniqueID("session"), uniqueID("se"), "")
	b, err := s.ObserveMachine(ctx, second)
	if err != nil || a.ID == b.ID {
		t.Fatalf("independent machine fixture: %v, %v", b, err)
	}
	blocker, err := s.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer blocker.Rollback(context.Background())
	if _, err := blocker.Exec(ctx, "SELECT id FROM darkbloom_machines WHERE id=$1 FOR UPDATE", b.ID); err != nil {
		t.Fatal(err)
	}
	blockerPID := blocker.Conn().PgConn().PID()
	second.VerifiedSerial = serial
	second.At = now.Add(time.Second)
	merged := make(chan error, 1)
	go func() {
		result, err := s.ObserveMachine(ctx, second)
		if err == nil && result.ID != a.ID {
			err = fmt.Errorf("merged machine = %q, want %q", result.ID, a.ID)
		}
		merged <- err
	}()
	waitFor := func(condition func() bool) {
		t.Helper()
		ticker := time.NewTicker(time.Millisecond)
		defer ticker.Stop()
		for !condition() {
			select {
			case <-ctx.Done():
				t.Fatal("concurrent merge did not reach expected state:", ctx.Err())
			case <-ticker.C:
			}
		}
	}
	// The merge now owns the inventory barrier and waits for our row lock.
	waitFor(func() bool {
		var waiting int
		err := s.pool.QueryRow(ctx, "SELECT count(*) FROM pg_stat_activity WHERE $1::int=ANY(pg_blocking_pids(pid))", blockerPID).Scan(&waiting)
		if err != nil {
			t.Fatal(err)
		}
		return waiting == 1
	})
	type admission struct {
		ok  bool
		err error
	}
	results := make(chan admission, 2)
	for _, scope := range []string{a.ID, b.ID} {
		record := AppAttestKeyRotation{KeyID: uniqueID("key"), MachineID: scope, AccountID: account, RequestedAt: now}
		go func() {
			_, ok, err := s.AdmitAppAttestKeyRotation(ctx, record, []AppAttestRotationLimit{{Window: time.Hour, Max: 1}})
			results <- admission{ok, err}
		}()
	}
	// Correct admissions block at the merge barrier. On the old code they both
	// finish while the merge is still paused; either path releases this gate.
	waitFor(func() bool {
		var waiting int
		err := s.pool.QueryRow(ctx, "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND classid=0 AND objid=9952701 AND NOT granted").Scan(&waiting)
		if err != nil {
			t.Fatal(err)
		}
		return waiting+len(results) >= 2
	})
	if err := blocker.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if err := <-merged; err != nil {
		t.Fatal("ObserveMachine merge:", err)
	}
	admitted := 0
	for range 2 {
		result := <-results
		if result.err != nil {
			t.Fatal(result.err)
		}
		if result.ok {
			admitted++
		}
	}
	if admitted != 1 {
		t.Fatalf("merge raced with admissions: %d rotations admitted, want exactly one", admitted)
	}
	if n, err := s.CountAppAttestKeyRotations(ctx, a.ID, now.Add(-time.Hour)); err != nil || n != 1 {
		t.Fatalf("surviving machine budget = %d (%v), want 1", n, err)
	}
}
