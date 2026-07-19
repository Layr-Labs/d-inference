package store

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"
)

func TestWithdrawableBalanceMigrationFirstRunAndRestart(t *testing.T) {
	databaseURL := newWithdrawableTestDatabase(t)
	s := newWithdrawableMigrationStore(t, databaseURL)
	prepareWithdrawableMigrationSchema(t, s, false)

	// Actual pre-split Stripe encoding: withdrawals were ordinary `charge`
	// entries with a stripe_withdraw: reference, while failures/reversals were
	// matching `refund` entries. The reconstruction must classify those direct
	// withdrawable deltas without treating inference charges as withdrawals.
	seedMigrationBalance(t, s, "legacy-withdrawal", 175, nil)
	seedMigrationLedger(t, s, "legacy-withdrawal", LedgerStripeDeposit, 100, 100, "deposit")
	seedMigrationLedger(t, s, "legacy-withdrawal", LedgerPayout, 100, 200, "payout")
	seedMigrationLedger(t, s, "legacy-withdrawal", LedgerCharge, -50, 150, "stripe_withdraw:legacy")
	seedMigrationLedger(t, s, "legacy-withdrawal", LedgerReferralReward, 25, 175, "referral")

	seedMigrationBalance(t, s, "legacy-reversal", 100, nil)
	seedMigrationLedger(t, s, "legacy-reversal", LedgerPayout, 100, 100, "payout")
	seedMigrationLedger(t, s, "legacy-reversal", LedgerCharge, -80, 20, "stripe_withdraw:reversed")
	seedMigrationLedger(t, s, "legacy-reversal", LedgerRefund, 80, 100, "stripe_withdraw:reversed")

	// Focused coverage for the remaining direct withdrawable entry types.
	seedMigrationBalance(t, s, "typed-deltas", 25, nil)
	seedMigrationLedger(t, s, "typed-deltas", LedgerAdminReward, 10, 10, "admin")
	seedMigrationLedger(t, s, "typed-deltas", LedgerFloorDraw, 20, 30, "floor")
	seedMigrationLedger(t, s, "typed-deltas", LedgerWithdrawal, -5, 25, "legacy-onchain")

	seedMigrationBalance(t, s, "capped-by-total", 25, nil)
	seedMigrationLedger(t, s, "capped-by-total", LedgerPayout, 100, 100, "payout")
	seedMigrationLedger(t, s, "capped-by-total", LedgerCharge, -75, 25, "inference")

	// Earned funds can be fully spent before a later non-withdrawable deposit.
	// A final-balance cap or aggregate SUM would incorrectly make the deposit
	// withdrawable; chronological provenance must leave this at zero.
	seedMigrationBalance(t, s, "spent-then-deposited", 50, nil)
	seedMigrationLedger(t, s, "spent-then-deposited", LedgerPayout, 100, 100, "payout")
	seedMigrationLedger(t, s, "spent-then-deposited", LedgerCharge, -100, 0, "inference")
	seedMigrationLedger(t, s, "spent-then-deposited", LedgerStripeDeposit, 50, 50, "later-deposit")

	seedMigrationBalance(t, s, "no-eligible-earnings", 100, nil)
	seedMigrationLedger(t, s, "no-eligible-earnings", LedgerStripeDeposit, 100, 100, "deposit")

	seedMigrationBalance(t, s, "negative-net-earnings", 10, nil)
	seedMigrationLedger(t, s, "negative-net-earnings", LedgerPayout, 50, 50, "payout")
	seedMigrationLedger(t, s, "negative-net-earnings", LedgerStripePayout, -50, 0, "withdrawal")
	seedMigrationLedger(t, s, "negative-net-earnings", LedgerStripeDeposit, 10, 10, "deposit")

	outcome, err := s.applyWithdrawableBalanceMigration(context.Background())
	if err != nil {
		t.Fatalf("first migration: %v", err)
	}
	if outcome.Result != withdrawableMigrationBackfilled || outcome.RowsAffected != 4 {
		t.Fatalf("first outcome = %+v, want backfilled with 4 changed rows", outcome)
	}
	for accountID, want := range map[string]int64{
		"legacy-withdrawal":     75,
		"legacy-reversal":       100,
		"typed-deltas":          25,
		"capped-by-total":       25,
		"spent-then-deposited":  0,
		"no-eligible-earnings":  0,
		"negative-net-earnings": 0,
	} {
		if got := migrationWithdrawableBalance(t, s, accountID); got != want {
			t.Errorf("%s withdrawable = %d, want %d", accountID, got, want)
		}
	}
	count, firstAppliedAt := migrationMarker(t, s)
	if count != 1 {
		t.Fatalf("marker count after first run = %d, want 1", count)
	}

	// Zero is now a legitimate live state. Add new eligible history that would
	// make the old every-startup statement recreate funds, then prove restart
	// skips without changing either the balance or the exact marker row.
	if _, err := s.pool.Exec(context.Background(),
		`UPDATE balances SET withdrawable_micro_usd = 0 WHERE account_id = 'capped-by-total'`); err != nil {
		t.Fatal(err)
	}
	seedMigrationLedger(t, s, "capped-by-total", LedgerPayout, 500, 525, "post-migration-payout")

	restart, err := s.applyWithdrawableBalanceMigration(context.Background())
	if err != nil {
		t.Fatalf("restart migration: %v", err)
	}
	if restart.Result != withdrawableMigrationSkipped || restart.RowsAffected != 0 {
		t.Fatalf("restart outcome = %+v, want already-applied skip", restart)
	}
	if got := migrationWithdrawableBalance(t, s, "capped-by-total"); got != 0 {
		t.Fatalf("restart recreated withdrawn funds: got %d, want 0", got)
	}
	count, secondAppliedAt := migrationMarker(t, s)
	if count != 1 || !secondAppliedAt.Equal(firstAppliedAt) {
		t.Fatalf("marker changed on restart: count=%d first=%s second=%s",
			count, firstAppliedAt, secondAppliedAt)
	}
}

func TestWithdrawableBalanceMigrationRejectsAmbiguousLegacyProvenance(t *testing.T) {
	tests := []struct {
		name string
		seed func(t *testing.T, s *PostgresStore)
	}{
		{
			name: "generic reservation refund",
			seed: func(t *testing.T, s *PostgresStore) {
				seedMigrationBalance(t, s, "ambiguous-refund", 100, nil)
				seedMigrationLedger(t, s, "ambiguous-refund", LedgerPayout, 100, 100, "payout")
				seedMigrationLedger(t, s, "ambiguous-refund", LedgerCharge, -100, 0, "reserve")
				seedMigrationLedger(t, s, "ambiguous-refund", LedgerRefund, 100, 100, "reservation_refund")
			},
		},
		{
			name: "generic refund with zero net direct deltas",
			seed: func(t *testing.T, s *PostgresStore) {
				seedMigrationBalance(t, s, "ambiguous-zero-net", 100, nil)
				seedMigrationLedger(t, s, "ambiguous-zero-net", LedgerPayout, 100, 100, "payout")
				seedMigrationLedger(t, s, "ambiguous-zero-net", LedgerStripePayout, -100, 0, "withdrawal")
				seedMigrationLedger(t, s, "ambiguous-zero-net", LedgerRefund, 100, 100, "reservation_refund")
			},
		},
		{
			name: "balance migration without withdrawable subset",
			seed: func(t *testing.T, s *PostgresStore) {
				seedMigrationBalance(t, s, "ambiguous-migration", 100, nil)
				seedMigrationLedger(t, s, "ambiguous-migration", LedgerMigration, 100, 100, "migrate:in")
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			databaseURL := newWithdrawableTestDatabase(t)
			s := newWithdrawableMigrationStore(t, databaseURL)
			prepareWithdrawableMigrationSchema(t, s, false)
			tt.seed(t, s)

			if _, err := s.applyWithdrawableBalanceMigration(context.Background()); err == nil {
				t.Fatal("ambiguous migration unexpectedly guessed withdrawable provenance")
			}
			if count, _ := migrationMarker(t, s); count != 0 {
				t.Fatalf("ambiguous migration left marker count %d, want 0", count)
			}
			var columnExists bool
			if err := s.pool.QueryRow(context.Background(), `
				SELECT EXISTS (
					SELECT 1 FROM information_schema.columns
					WHERE table_schema = current_schema()
					  AND table_name = 'balances'
					  AND column_name = 'withdrawable_micro_usd'
				)`).Scan(&columnExists); err != nil {
				t.Fatal(err)
			}
			if columnExists {
				t.Fatal("ambiguous migration committed the withdrawable column")
			}
		})
	}
}

func TestWithdrawableBalanceMigrationPreservesLiveAccounting(t *testing.T) {
	databaseURL := newWithdrawableTestDatabase(t)
	s := newWithdrawableMigrationStore(t, databaseURL)
	prepareWithdrawableMigrationSchema(t, s, true)

	zero := int64(0)
	refunded := int64(80)
	migrated := int64(40)
	floorDraw := int64(30)
	seedMigrationBalance(t, s, "withdrawn-to-zero", 50, &zero)
	seedMigrationLedger(t, s, "withdrawn-to-zero", LedgerPayout, 100, 100, "earning")
	seedMigrationLedger(t, s, "withdrawn-to-zero", LedgerStripePayout, -100, 0, "withdrawal")
	seedMigrationLedger(t, s, "withdrawn-to-zero", LedgerStripeDeposit, 50, 50, "later-deposit")

	seedMigrationBalance(t, s, "reversed-withdrawal", 80, &refunded)
	seedMigrationLedger(t, s, "reversed-withdrawal", LedgerPayout, 100, 100, "earning")
	seedMigrationLedger(t, s, "reversed-withdrawal", LedgerStripePayout, -100, 0, "withdrawal")
	seedMigrationLedger(t, s, "reversed-withdrawal", LedgerRefund, 80, 80, "stripe_withdraw:refund")

	seedMigrationBalance(t, s, "migration-source", 0, &zero)
	seedMigrationLedger(t, s, "migration-source", LedgerPayout, 100, 100, "earning")
	seedMigrationLedger(t, s, "migration-source", LedgerMigration, -100, 0, "migrate:out")
	seedMigrationBalance(t, s, "migration-destination", 100, &migrated)
	seedMigrationLedger(t, s, "migration-destination", LedgerMigration, 100, 100, "migrate:in")

	seedMigrationBalance(t, s, "floor-draw", 30, &floorDraw)
	seedMigrationLedger(t, s, "floor-draw", LedgerFloorDraw, 30, 30, "floor")

	outcome, err := s.applyWithdrawableBalanceMigration(context.Background())
	if err != nil {
		t.Fatalf("preservation migration: %v", err)
	}
	if outcome.Result != withdrawableMigrationPreserved || outcome.RowsAffected != 0 {
		t.Fatalf("outcome = %+v, want existing-schema preservation", outcome)
	}
	for accountID, want := range map[string]int64{
		"withdrawn-to-zero":     0,
		"reversed-withdrawal":   80,
		"migration-source":      0,
		"migration-destination": 40,
		"floor-draw":            30,
	} {
		if got := migrationWithdrawableBalance(t, s, accountID); got != want {
			t.Errorf("%s withdrawable changed: got %d, want %d", accountID, got, want)
		}
	}
	if count, _ := migrationMarker(t, s); count != 1 {
		t.Fatalf("marker count = %d, want 1", count)
	}
}

func TestPostgresStartupRunsWithdrawableMigrationOnce(t *testing.T) {
	databaseURL := newWithdrawableTestDatabase(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	first, err := NewPostgres(ctx, Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatalf("first NewPostgres: %v", err)
	}
	if count, _ := migrationMarker(t, first); count != 1 {
		first.Close()
		t.Fatalf("first startup marker count = %d, want 1", count)
	}
	if err := first.CreditWithdrawable("live-zero", 100, LedgerPayout, "earning"); err != nil {
		first.Close()
		t.Fatalf("credit live balance: %v", err)
	}
	if err := first.DebitWithdrawable("live-zero", 100, LedgerStripePayout, "withdrawal"); err != nil {
		first.Close()
		t.Fatalf("withdraw live balance: %v", err)
	}
	first.Close()

	restart, err := NewPostgres(ctx, Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatalf("restart NewPostgres: %v", err)
	}
	defer restart.Close()
	if got := restart.GetWithdrawableBalance("live-zero"); got != 0 {
		t.Fatalf("restart recreated withdrawn funds: got %d, want 0", got)
	}
	if count, _ := migrationMarker(t, restart); count != 1 {
		t.Fatalf("restart marker count = %d, want 1", count)
	}
}

func TestWithdrawableBalanceMigrationConcurrentReplicas(t *testing.T) {
	for attempt := 0; attempt < 5; attempt++ {
		t.Run(fmt.Sprintf("attempt-%d", attempt), func(t *testing.T) {
			databaseURL := newWithdrawableTestDatabase(t)
			first := newWithdrawableMigrationStore(t, databaseURL)
			second := newWithdrawableMigrationStore(t, databaseURL)
			prepareWithdrawableMigrationSchema(t, first, false)
			seedMigrationBalance(t, first, "concurrent", 50, nil)
			seedMigrationLedger(t, first, "concurrent", LedgerPayout, 50, 50, "earning")

			if _, err := first.pool.Exec(context.Background(), `
				CREATE FUNCTION delay_withdrawable_backfill()
				RETURNS trigger LANGUAGE plpgsql AS $$
				BEGIN
					PERFORM pg_sleep(0.1);
					RETURN NEW;
				END $$;
				CREATE TRIGGER delay_withdrawable_backfill
				BEFORE UPDATE ON balances
				FOR EACH ROW EXECUTE FUNCTION delay_withdrawable_backfill()`); err != nil {
				t.Fatalf("install overlap trigger: %v", err)
			}

			start := make(chan struct{})
			outcomes := make(chan withdrawableMigrationOutcome, 2)
			errs := make(chan error, 2)
			var wg sync.WaitGroup
			for _, replica := range []*PostgresStore{first, second} {
				wg.Add(1)
				go func(s *PostgresStore) {
					defer wg.Done()
					<-start
					outcome, err := s.applyWithdrawableBalanceMigration(context.Background())
					outcomes <- outcome
					errs <- err
				}(replica)
			}
			close(start)
			wg.Wait()
			close(outcomes)
			close(errs)

			for err := range errs {
				if err != nil {
					t.Fatalf("concurrent migration: %v", err)
				}
			}
			var backfilled, skipped int
			for outcome := range outcomes {
				switch outcome.Result {
				case withdrawableMigrationBackfilled:
					backfilled++
				case withdrawableMigrationSkipped:
					skipped++
				default:
					t.Fatalf("unexpected concurrent outcome: %+v", outcome)
				}
			}
			if backfilled != 1 || skipped != 1 {
				t.Fatalf("concurrent outcomes backfilled=%d skipped=%d, want 1/1", backfilled, skipped)
			}
			if got := migrationWithdrawableBalance(t, first, "concurrent"); got != 50 {
				t.Fatalf("withdrawable = %d, want 50", got)
			}
			if count, _ := migrationMarker(t, first); count != 1 {
				t.Fatalf("marker count = %d, want 1", count)
			}
		})
	}
}

func TestWithdrawableBalanceMigrationBlockedReplicaTakesOverAfterRollback(t *testing.T) {
	databaseURL := newWithdrawableTestDatabase(t)
	first := newWithdrawableMigrationStore(t, databaseURL)
	second := newWithdrawableMigrationStore(t, databaseURL)
	prepareWithdrawableMigrationSchema(t, first, false)
	seedMigrationBalance(t, first, "rollback-takeover", 60, nil)
	seedMigrationLedger(t, first, "rollback-takeover", LedgerPayout, 60, 60, "earning")

	// Sequences are intentionally non-transactional. The first claimant sleeps
	// while holding the uncommitted unique marker, then fails. The waiter is
	// already blocked on that marker; after rollback it acquires the claim, sees
	// sequence value 2, and completes the whole migration.
	if _, err := first.pool.Exec(context.Background(), `
		CREATE SEQUENCE fail_first_withdrawable_backfill;
		CREATE FUNCTION fail_first_withdrawable_backfill()
		RETURNS trigger LANGUAGE plpgsql AS $$
		BEGIN
			IF nextval('fail_first_withdrawable_backfill') = 1 THEN
				PERFORM pg_sleep(0.3);
				RAISE EXCEPTION 'forced first claimant rollback';
			END IF;
			RETURN NEW;
		END $$;
		CREATE TRIGGER fail_first_withdrawable_backfill
			BEFORE UPDATE ON balances
			FOR EACH ROW EXECUTE FUNCTION fail_first_withdrawable_backfill()`); err != nil {
		t.Fatalf("install one-shot failure trigger: %v", err)
	}

	type migrationCall struct {
		outcome withdrawableMigrationOutcome
		err     error
	}
	firstDone := make(chan migrationCall, 1)
	secondDone := make(chan migrationCall, 1)
	go func() {
		outcome, err := first.applyWithdrawableBalanceMigration(context.Background())
		firstDone <- migrationCall{outcome: outcome, err: err}
	}()
	triggerDeadline := time.Now().Add(2 * time.Second)
	for {
		var firstClaimantEnteredTrigger bool
		if err := second.pool.QueryRow(context.Background(),
			`SELECT is_called FROM fail_first_withdrawable_backfill`,
		).Scan(&firstClaimantEnteredTrigger); err != nil {
			t.Fatalf("observe first claimant trigger: %v", err)
		}
		if firstClaimantEnteredTrigger {
			break
		}
		if time.Now().After(triggerDeadline) {
			t.Fatal("first claimant did not reach the failure trigger")
		}
		time.Sleep(5 * time.Millisecond)
	}
	go func() {
		outcome, err := second.applyWithdrawableBalanceMigration(context.Background())
		secondDone <- migrationCall{outcome: outcome, err: err}
	}()

	select {
	case result := <-secondDone:
		t.Fatalf("second replica did not wait on uncommitted marker: %+v", result)
	case <-time.After(100 * time.Millisecond):
	}

	failed := <-firstDone
	if failed.err == nil {
		t.Fatalf("first claimant unexpectedly committed: %+v", failed.outcome)
	}
	takeover := <-secondDone
	if takeover.err != nil {
		t.Fatalf("blocked replica failed to take over: %v", takeover.err)
	}
	if takeover.outcome.Result != withdrawableMigrationBackfilled || takeover.outcome.RowsAffected != 1 {
		t.Fatalf("takeover outcome = %+v, want one-row backfill", takeover.outcome)
	}
	if got := migrationWithdrawableBalance(t, second, "rollback-takeover"); got != 60 {
		t.Fatalf("takeover withdrawable = %d, want 60", got)
	}
	if count, _ := migrationMarker(t, second); count != 1 {
		t.Fatalf("takeover marker count = %d, want 1", count)
	}
}

func TestWithdrawableBalanceMigrationFailureRollsBackAndRetries(t *testing.T) {
	databaseURL := newWithdrawableTestDatabase(t)
	s := newWithdrawableMigrationStore(t, databaseURL)
	prepareWithdrawableMigrationSchema(t, s, false)
	seedMigrationBalance(t, s, "retry", 75, nil)
	seedMigrationLedger(t, s, "retry", LedgerPayout, 75, 75, "earning")

	if _, err := s.pool.Exec(context.Background(), `
		CREATE FUNCTION reject_withdrawable_backfill()
		RETURNS trigger LANGUAGE plpgsql AS $$
		BEGIN
			RAISE EXCEPTION 'forced withdrawable migration failure';
		END $$;
		CREATE TRIGGER reject_withdrawable_backfill
			BEFORE UPDATE ON balances
			FOR EACH ROW EXECUTE FUNCTION reject_withdrawable_backfill()`); err != nil {
		t.Fatalf("install failure trigger: %v", err)
	}

	if _, err := s.applyWithdrawableBalanceMigration(context.Background()); err == nil {
		t.Fatal("migration unexpectedly succeeded through failure trigger")
	}
	if count, _ := migrationMarker(t, s); count != 0 {
		t.Fatalf("failed migration left marker count %d, want 0", count)
	}
	var columnExists bool
	if err := s.pool.QueryRow(context.Background(), `
		SELECT EXISTS (
			SELECT 1 FROM information_schema.columns
			WHERE table_schema = current_schema()
			  AND table_name = 'balances'
			  AND column_name = 'withdrawable_micro_usd'
		)`).Scan(&columnExists); err != nil {
		t.Fatal(err)
	}
	if columnExists {
		t.Fatal("failed migration committed the withdrawable column")
	}

	if _, err := s.pool.Exec(context.Background(), `
		DROP TRIGGER reject_withdrawable_backfill ON balances;
		DROP FUNCTION reject_withdrawable_backfill()`); err != nil {
		t.Fatalf("remove failure trigger: %v", err)
	}
	outcome, err := s.applyWithdrawableBalanceMigration(context.Background())
	if err != nil {
		t.Fatalf("retry migration: %v", err)
	}
	if outcome.Result != withdrawableMigrationBackfilled || outcome.RowsAffected != 1 {
		t.Fatalf("retry outcome = %+v, want one-row backfill", outcome)
	}
	if got := migrationWithdrawableBalance(t, s, "retry"); got != 75 {
		t.Fatalf("retry withdrawable = %d, want 75", got)
	}
	if count, _ := migrationMarker(t, s); count != 1 {
		t.Fatalf("retry marker count = %d, want 1", count)
	}
}

func TestWithdrawableBalanceMigrationRestartDoesNotScanFinancialTables(t *testing.T) {
	databaseURL := newWithdrawableTestDatabase(t)
	locker := newWithdrawableMigrationStore(t, databaseURL)
	restart := newWithdrawableMigrationStore(t, databaseURL)
	prepareWithdrawableMigrationSchema(t, locker, true)
	if _, err := locker.pool.Exec(context.Background(),
		`INSERT INTO schema_migrations (id) VALUES ($1)`,
		withdrawableBalanceMigrationID); err != nil {
		t.Fatalf("seed migration marker: %v", err)
	}

	lockTx, err := locker.pool.Begin(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer lockTx.Rollback(context.Background())
	if _, err := lockTx.Exec(context.Background(),
		`LOCK TABLE balances, ledger_entries IN ACCESS EXCLUSIVE MODE`); err != nil {
		t.Fatalf("lock financial tables: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	outcome, err := restart.applyWithdrawableBalanceMigration(ctx)
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			t.Fatal("restart touched or scanned a locked financial table")
		}
		t.Fatalf("restart migration: %v", err)
	}
	if outcome.Result != withdrawableMigrationSkipped {
		t.Fatalf("restart outcome = %+v, want already-applied skip", outcome)
	}
}
