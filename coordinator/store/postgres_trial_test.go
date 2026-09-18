package store

import (
	"context"
	"fmt"
	"os"
	"testing"
)

func TestTrialPostgresRestartAndRollback(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	r := trialRequest("restart", "account", 100)
	reserveAndDispatch(t, s, r)
	// A new pool represents an independent coordinator process sharing the DB.
	other, err := NewPostgres(ctx, Config{DatabaseURL: os.Getenv("DATABASE_URL")})
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	assertAllowance(t, other, r, 0, 100)
	// Fail after provider credit and usage insertion. Everything must roll back.
	_, err = s.pool.Exec(ctx, `ALTER TABLE trial_subsidies ADD CONSTRAINT reject_test_subsidy CHECK(subsidy_micro_usd <> 100)`)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = s.pool.Exec(context.Background(), `ALTER TABLE trial_subsidies DROP CONSTRAINT IF EXISTS reject_test_subsidy`)
	})
	requireTrialError(t, other.SettleTrial(ctx, r.ID, trialSettlement(r, 20, 10)), ErrTrialUnavailable)
	assertAllowance(t, s, r, 0, 100)
	if s.GetBalance("provider-account") != 0 || len(s.UsageByConsumer("account")) != 0 {
		t.Fatal("partial transaction escaped rollback")
	}
	_, err = s.pool.Exec(ctx, `ALTER TABLE trial_subsidies DROP CONSTRAINT reject_test_subsidy`)
	if err != nil {
		t.Fatal(err)
	}
	if err = other.SettleTrial(ctx, r.ID, trialSettlement(r, 20, 10)); err != nil {
		t.Fatal(err)
	}
	assertAllowance(t, s, r, 30, 0)
	var subsidy, credit int64
	if err = s.pool.QueryRow(ctx, `SELECT subsidy_micro_usd,provider_credit_micro_usd FROM trial_subsidies WHERE reservation_id=$1`, r.ID).Scan(&subsidy, &credit); err != nil || subsidy != 100 || credit != 80 {
		t.Fatalf("subsidy=%d credit=%d err=%v", subsidy, credit, err)
	}
}

func TestTrialPostgresIndependentCoordinators(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	other, err := NewPostgres(ctx, Config{DatabaseURL: os.Getenv("DATABASE_URL")})
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	start := make(chan struct{})
	errs := make(chan error, 2)
	for i, st := range []TrialStore{s, other} {
		go func(i int, st TrialStore) {
			<-start
			_, err := st.ReserveTrial(ctx, trialRequest(fmt.Sprint("cross-process-", i), "account", 700))
			errs <- err
		}(i, st)
	}
	close(start)
	success := 0
	for i := 0; i < 2; i++ {
		err := <-errs
		if err == nil {
			success++
		} else {
			requireTrialError(t, err, ErrTrialBusy)
		}
	}
	if success != 1 {
		t.Fatalf("admissions=%d", success)
	}
	assertAllowance(t, s, trialRequest("", "account", 0), 0, 700)
}
