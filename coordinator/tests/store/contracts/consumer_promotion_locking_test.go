package store_test

import (
	"context"
	"net/url"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/postgres"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestPostgresConsumerAndPromotionSettlementMissingReferrerBalance(t *testing.T) {
	s := testPostgresStore(t)
	promotions, _ := promotionFixture(t, s, 10)
	seedConsumerReferral(t, s, "consumer", "z-referrer")
	if err := s.Credit("consumer", 1000, store.LedgerDeposit, "seed"); err != nil {
		t.Fatal(err)
	}
	r, err := promotions.ReserveModelTokens("promotion", "consumer", "not-registered/model", 50, tokenPrice(50))
	if err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	ordinaryURL, err := url.Parse(os.Getenv("DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	query := ordinaryURL.Query()
	query.Set("application_name", "ordinary-settlement-lock-test")
	ordinaryURL.RawQuery = query.Encode()
	ordinary, err := postgres.NewPostgres(ctx, store.Config{DatabaseURL: ordinaryURL.String()})
	if err != nil {
		t.Fatal(err)
	}
	defer ordinary.Close()

	// Pause only ordinary settlement immediately before it inserts the missing
	// referrer balance. The old path already held the consumer row at this point.
	_, err = pool.Exec(ctx, `CREATE FUNCTION pause_ordinary_referrer_insert() RETURNS trigger LANGUAGE plpgsql AS $$
	BEGIN
		IF NEW.account_id = 'z-referrer' AND current_setting('application_name') = 'ordinary-settlement-lock-test' THEN
			PERFORM pg_advisory_xact_lock(9952703);
		END IF;
		RETURN NEW;
	END $$;
	CREATE TRIGGER pause_ordinary_referrer_insert BEFORE INSERT ON balances
	FOR EACH ROW EXECUTE FUNCTION pause_ordinary_referrer_insert()`)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if _, err := pool.Exec(context.Background(), `DROP TRIGGER pause_ordinary_referrer_insert ON balances; DROP FUNCTION pause_ordinary_referrer_insert()`); err != nil {
			t.Error(err)
		}
	}()
	blocker, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer blocker.Rollback(context.Background())
	var blockerPID int
	if err := blocker.QueryRow(ctx, `SELECT pg_backend_pid() FROM pg_advisory_xact_lock(9952703)`).Scan(&blockerPID); err != nil {
		t.Fatal(err)
	}
	input := store.ConsumerChargeSettlement{AccountID: "consumer", JobID: "ordinary", CostMicroUSD: 400, ReferralEnabled: true}
	ordinaryDone := make(chan error, 1)
	go func() {
		_, err := ordinary.FinalizeConsumerCharge(input)
		ordinaryDone <- err
	}()

	ticker := time.NewTicker(time.Millisecond)
	defer ticker.Stop()
	var ordinaryPID int
	for ordinaryPID == 0 {
		if err := pool.QueryRow(ctx, `SELECT COALESCE(MAX(pid),0) FROM pg_stat_activity
			WHERE datname=current_database() AND application_name='ordinary-settlement-lock-test'
			AND $1::int=ANY(pg_blocking_pids(pid))`, blockerPID).Scan(&ordinaryPID); err != nil {
			t.Fatal(err)
		}
		if ordinaryPID == 0 {
			select {
			case err := <-ordinaryDone:
				t.Fatalf("ordinary settlement returned before the insert barrier: %v", err)
			case <-ctx.Done():
				t.Fatal(ctx.Err())
			case <-ticker.C:
			}
		}
	}

	promotionDone := make(chan error, 1)
	go func() {
		_, err := promotions.SettleModelTokenReservation(r.ID, 50, tokenPrice(50), nil)
		promotionDone <- err
	}()
	// Observe either promotion completion (correct ordering) or its wait for
	// ordinary's consumer lock (old ordering), never guess using a fixed sleep.
	promotionFinished := false
	var promotionErr error
	for {
		var blocked bool
		if err := pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM pg_stat_activity
			WHERE datname=current_database() AND $1::int=ANY(pg_blocking_pids(pid)))`, ordinaryPID).Scan(&blocked); err != nil {
			t.Fatal(err)
		}
		if blocked {
			break
		}
		select {
		case promotionErr = <-promotionDone:
			promotionFinished = true
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		case <-ticker.C:
		}
		if promotionFinished {
			break
		}
	}
	if err := blocker.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if err := <-ordinaryDone; err != nil {
		t.Errorf("ordinary settlement: %v", err)
	}
	if !promotionFinished {
		promotionErr = <-promotionDone
	}
	if promotionErr != nil {
		t.Errorf("promotion settlement: %v", promotionErr)
	}
	if t.Failed() {
		return
	}
	if s.GetBalance("consumer") != 560 || s.GetWithdrawableBalance("z-referrer") != 22 {
		t.Fatalf("consumer=%d referrer=%d", s.GetBalance("consumer"), s.GetWithdrawableBalance("z-referrer"))
	}
	stats, err := s.GetReferralStats("z-referrer")
	if err != nil || stats.TotalReferredSpendMicroUSD != 440 || stats.TotalRewardsMicroUSD != 22 {
		t.Fatalf("stats=%+v err=%v", stats, err)
	}
	if result, err := ordinary.FinalizeConsumerCharge(input); err != nil || result.Applied {
		t.Fatalf("ordinary replay=%+v err=%v", result, err)
	}
	if result, err := promotions.SettleModelTokenReservation(r.ID, 50, tokenPrice(50), nil); err != nil || result.Applied {
		t.Fatalf("promotion replay=%+v err=%v", result, err)
	}
}
