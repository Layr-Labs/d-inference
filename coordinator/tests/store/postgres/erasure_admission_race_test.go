package postgres_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

func waitErasureLock(t *testing.T, s *postgresFixture, query string, count int) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	for ctx.Err() == nil {
		var n int
		if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND pid<>pg_backend_pid() AND wait_event_type='Lock' AND query ILIKE $1`, "%"+query+"%").Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n >= count {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("expected %d blocked queries containing %q", count, query)
}

func TestErasureConfirmationWaitsForWithdrawalAdmission(t *testing.T) {
	ctx := context.Background()
	s := testPostgresStore(t)
	a := erasurefixture.SeedAccount(t, s)
	now := time.Now().UTC()
	plan, err := s.PlanAccountErasure(ctx, a.AccountID, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.SaveErasurePlan(ctx, a.AccountID, "admin", plan.ErasureCounts, nil, "confirm", now.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	hold, err := s.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer hold.Rollback(ctx)
	if _, err := hold.Exec(ctx, `LOCK TABLE ledger_entries IN ACCESS EXCLUSIVE MODE`); err != nil {
		t.Fatal(err)
	}
	withdraw := make(chan error, 1)
	go func() {
		withdraw <- s.CreateStripeWithdrawalWithDebit(&store.StripeWithdrawal{ID: erasurefixture.UniqueID("withdrawal"), AccountID: a.AccountID, StripeAccountID: a.Stripe, AmountMicroUSD: 1000, NetMicroUSD: 1000, Status: "pending", Method: "standard"}, store.LedgerStripePayout, "withdrawal-race")
	}()
	waitErasureLock(t, s, "INSERT INTO ledger_entries", 1)
	confirm := make(chan error, 1)
	go func() {
		_, err := s.RequestAccountErasure(ctx, store.ErasureConfirm{AccountID: a.AccountID, ConfirmToken: "confirm", Email: a.Email, Now: now})
		confirm <- err
	}()
	waitErasureLock(t, s, "FROM users WHERE account_id = $1 FOR UPDATE", 1)
	if err := hold.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if err := <-withdraw; err != nil {
		t.Fatal(err)
	}
	if err := <-confirm; !errors.Is(err, store.ErrErasureOpenWithdrawal) {
		t.Fatalf("confirmation=%v, want open withdrawal", err)
	}
	if _, err := s.GetUserByAccountID(a.AccountID); err != nil {
		t.Fatalf("confirmation erased account despite withdrawal: %v", err)
	}
}

func TestErasureConcurrentSharedOwnersFinishCleanup(t *testing.T) {
	ctx := context.Background()
	s := testPostgresStore(t)
	a := erasurefixture.SeedAccount(t, s)
	b := erasurefixture.SeedAccount(t, s)
	now := time.Now().UTC()
	if _, err := s.pool.Exec(ctx, `UPDATE providers SET se_public_key=$1 WHERE id=$2`, a.SEKey, b.ProviderID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.pool.Exec(ctx, `INSERT INTO provider_trust_reuse(se_pubkey,serial) VALUES($1,'shared-serial')`, a.SEKey); err != nil {
		t.Fatal(err)
	}
	ra := erasurefixture.PlanAndConfirm(t, s, a, now, 0)
	rb := erasurefixture.PlanAndConfirm(t, s, b, now, 0)
	hold, err := s.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer hold.Rollback(ctx)
	if _, err := hold.Exec(ctx, `SELECT pg_advisory_xact_lock(714320,1)`); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 2)
	for _, id := range []string{ra.ID, rb.ID} {
		go func() { _, err := s.ScrubAccount(ctx, id, now); done <- err }()
	}
	waitErasureLock(t, s, "pg_advisory_xact_lock(714320, 1)", 2)
	if err := hold.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if err := <-done; err != nil {
			t.Fatal(err)
		}
	}
	var n int
	if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM provider_trust_reuse WHERE se_pubkey=$1`, a.SEKey).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatal("concurrent erasures each retained the other's personal trust data")
	}
}
