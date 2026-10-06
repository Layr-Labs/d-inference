package postgres_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

func TestErasureOutboxRechecksExpiryAfterRowLock(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	s := testPostgresStore(t)
	a := erasurefixture.SeedAccount(t, s)
	now := time.Now().UTC()
	req := erasurefixture.PlanAndConfirm(t, s, a, now, 0)
	if _, err := s.ScrubAccount(ctx, req.ID, now); err != nil {
		t.Fatal(err)
	}
	rows, err := s.LeaseDueErasureOutbox(ctx, now, now, time.Minute, 1)
	if err != nil || len(rows) != 1 {
		t.Fatalf("claim = %+v, %v", rows, err)
	}
	row := rows[0]
	if _, err := s.pool.Exec(ctx, `UPDATE erasure_outbox SET lease_until = clock_timestamp() + interval '1 second' WHERE id = $1`, row.ID); err != nil {
		t.Fatal(err)
	}
	holder, err := s.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer holder.Rollback(context.Background())
	if _, err := holder.Exec(ctx, `SELECT id FROM erasure_outbox WHERE id = $1 FOR UPDATE`, row.ID); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		done <- s.SaveErasureOutboxResult(ctx, row.ID, store.ErasureOutboxResult{
			LeaseGeneration: row.LeaseGeneration, State: store.ErasureOutboxDone, NextAt: now,
			Split: &store.ErasureOutboxItem{ID: "expired-split", RequestID: req.ID, Target: store.ErasureTargetCheckoutSessions, ExternalID: "cs_missing"},
		})
	}()
	// Observe the actual waiter, then retain only a row lock until the
	// database clock passes the lease. No intervening row update forces an
	// UPDATE predicate recheck: Save must check time after acquiring the lock.
	waitOutboxCondition(t, ctx, func() (bool, error) {
		var waiting bool
		err := s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid)))`, holder.Conn().PgConn().PID()).Scan(&waiting)
		return waiting, err
	})
	waitOutboxCondition(t, ctx, func() (bool, error) {
		var expired bool
		err := s.pool.QueryRow(ctx, `SELECT clock_timestamp() >= lease_until FROM erasure_outbox WHERE id = $1`, row.ID).Scan(&expired)
		return expired, err
	})
	if err := holder.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if err := <-done; !errors.Is(err, store.ErrErasureConflict) {
		t.Fatalf("save after lock wait = %v; want ErrErasureConflict", err)
	}
	var state string
	var splits int
	if err := s.pool.QueryRow(ctx, `SELECT state FROM erasure_outbox WHERE id = $1`, row.ID).Scan(&state); err != nil {
		t.Fatal(err)
	}
	if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM erasure_outbox WHERE id = 'expired-split'`).Scan(&splits); err != nil {
		t.Fatal(err)
	}
	if state != "pending" || splits != 0 {
		t.Fatalf("expired result mutated state=%s, splits=%d", state, splits)
	}
}

func waitOutboxCondition(t *testing.T, ctx context.Context, check func() (bool, error)) {
	t.Helper()
	for {
		ok, err := check()
		if err != nil {
			t.Fatal(err)
		}
		if ok {
			return
		}
		select {
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		case <-time.After(5 * time.Millisecond):
		}
	}
}

func TestErasureOutboxDoesNotDeliverStagedDeletion(t *testing.T) {
	ctx := context.Background()
	s := testPostgresStore(t)
	a := erasurefixture.SeedAccount(t, s)
	now := time.Now().UTC()
	req := erasurefixture.PlanAndConfirm(t, s, a, now, time.Hour)
	// A late external creation can finish after soft deletion, before the
	// grace period ends. Its cleanup is staged without authorizing delivery.
	if _, err := s.pool.Exec(ctx, `INSERT INTO erasure_outbox (id, request_id, target, external_id, next_at) VALUES ('staged-external', $1, 'stripe_account', 'acct_late', $2)`, req.ID, now); err != nil {
		t.Fatal(err)
	}
	for _, state := range []store.ErasureState{store.ErasurePending, store.ErasureCanceled} {
		if state == store.ErasureCanceled {
			if _, err := s.CancelAccountErasure(ctx, a.AccountID, "admin_key", now); err != nil {
				t.Fatal(err)
			}
		}
		rows, err := s.LeaseDueErasureOutbox(ctx, now, now, time.Minute, 20)
		if err != nil || len(rows) != 0 {
			t.Fatalf("request %s yielded staged delivery: %+v, %v", state, rows, err)
		}
	}
	var externalID string
	var generation int64
	if err := s.pool.QueryRow(ctx, `SELECT external_id, lease_generation FROM erasure_outbox WHERE id = 'staged-external'`).Scan(&externalID, &generation); err != nil {
		t.Fatal(err)
	}
	if externalID != "acct_late" || generation != 0 {
		t.Fatalf("quarantined row changed: external_id=%s generation=%d", externalID, generation)
	}
}
