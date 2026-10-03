package store

import (
	"context"
	"testing"
	"time"
)

// The scrub takes billing_sessions before balances, like
// CompleteStripeCheckout. A checkout that holds its session lock can then
// still take the balance lock while the scrub waits; the reverse order
// deadlocks.
func TestScrubLocksBillingSessionsBeforeBalances(t *testing.T) {
	ctx := context.Background()
	s := testPostgresStore(t)
	a := seedErasureAccount(t, s)
	now := time.Now().UTC()
	req := planAndConfirm(t, s, a, now, 0)

	checkout, err := s.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer checkout.Rollback(ctx)
	if _, err := checkout.Exec(ctx, `SELECT id FROM billing_sessions WHERE account_id = $1 FOR UPDATE`, a.AccountID); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		_, err := s.ScrubAccount(ctx, req.ID, now)
		done <- err
	}()
	time.Sleep(300 * time.Millisecond)
	if _, err := checkout.Exec(ctx, `SET LOCAL lock_timeout = '2s'`); err != nil {
		t.Fatal(err)
	}
	if _, err := checkout.Exec(ctx, `UPDATE balances SET updated_at = NOW() WHERE account_id = $1`, a.AccountID); err != nil {
		t.Fatalf("checkout could not take the balance lock while the scrub waited: %v", err)
	}
	if err := checkout.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatalf("scrub after the checkout: %v", err)
	}
}

// Every erasure step locks users before erasure_requests. While another
// transaction holds the user row, RequestAccountErasure must not hold the
// request row.
func TestRequestAccountErasureLocksUserFirst(t *testing.T) {
	ctx := context.Background()
	s := testPostgresStore(t)
	a := seedErasureAccount(t, s)
	now := time.Now().UTC()
	plan, err := s.PlanAccountErasure(ctx, a.AccountID, nil)
	if err != nil {
		t.Fatal(err)
	}
	saved, err := s.SaveErasurePlan(ctx, a.AccountID, "admin_key", plan.ErasureCounts, nil, "token", now.Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	other, err := s.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer other.Rollback(ctx)
	if _, err := other.Exec(ctx, `SELECT 1 FROM users WHERE account_id = $1 FOR UPDATE`, a.AccountID); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		_, err := s.RequestAccountErasure(ctx, ErasureConfirm{AccountID: a.AccountID, ConfirmToken: "token", Email: a.Email, Now: now, Grace: time.Hour})
		done <- err
	}()
	time.Sleep(300 * time.Millisecond)
	if _, err := other.Exec(ctx, `SELECT 1 FROM erasure_requests WHERE id = $1 FOR UPDATE NOWAIT`, saved.ID); err != nil {
		t.Fatalf("RequestAccountErasure took the request lock before the user lock: %v", err)
	}
	if err := other.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}
