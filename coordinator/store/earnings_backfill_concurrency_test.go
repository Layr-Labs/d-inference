package store

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func seededLegacyEarningsStore(t *testing.T) *PostgresStore {
	t.Helper()
	s, err := NewPostgres(context.Background(), Config{DatabaseURL: newWithdrawableTestDatabase(t)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	_, err = s.pool.Exec(context.Background(), `DELETE FROM schema_migrations WHERE id=ANY($1::text[]);
 `, []string{earningsSummaryMigrationID, earningsSummaryPlanID, earningsSummaryPlanAttemptID})
	if err != nil {
		t.Fatal(err)
	}
	// Simulate legacy history with no summary. Base-reward rows contain tokens
	// deliberately: money must survive, while non-inference work stays zero.
	_, err = s.pool.Exec(context.Background(), `INSERT INTO provider_earnings(account_id,provider_id,provider_key,job_id,model,amount_micro_usd,prompt_tokens,completion_tokens)
 VALUES('a','old','p','historical-work','m',300,20,30),('a','old','p','historical-floor','base_reward',700,999,999)`)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func executeOldServingCredit(t *testing.T, tx pgx.Tx) {
	t.Helper()
	sql, err := os.ReadFile("testdata/credit_provider_account_884d97862.sql")
	if err != nil {
		t.Fatal(err)
	}
	var balance int64
	err = tx.QueryRow(context.Background(), string(sql), "a", int64(50), string(LedgerPayout), "live-work", nil, "live", "p", "m", 5, 7).Scan(&balance)
	if err != nil {
		t.Fatal(err)
	}
}

func assertBackfilledWork(t *testing.T, s *PostgresStore) {
	t.Helper()
	for _, key := range []string{"a", "p"} {
		var n, money, prompt, completion int64
		err := s.pool.QueryRow(context.Background(), `SELECT total_count,total_micro_usd,total_prompt_tokens,total_completion_tokens FROM earnings_summary WHERE key=$1`, key).Scan(&n, &money, &prompt, &completion)
		if err != nil || n != 2 || money != 1050 || prompt != 25 || completion != 37 {
			t.Fatalf("%s summary=(%d,%d,%d,%d), err=%v; want(2,1050,25,37)", key, n, money, prompt, completion, err)
		}
	}
}

func TestEarningsSummaryBackfillOldWriterCommitBeforeApply(t *testing.T) {
	s := seededLegacyEarningsStore(t)
	ctx := context.Background()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	executeOldServingCredit(t, tx) // earning + both summaries exist but are uncommitted
	// Planning must not wait on the old writer's row locks. Its single snapshot
	// sees historical work/base rewards and neither half of the uncommitted CTE.
	planCtx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	if err := prepareEarningsSummaryBackfill(planCtx, s.pool, s.claimEarningsSummaryAttempt); err != nil {
		t.Fatalf("planning blocked old writer: %v", err)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := s.applyEarningsSummaryMigration(ctx); err != nil {
		t.Fatal(err)
	}
	assertBackfilledWork(t, s)
	// A second boot must not add the captured history twice.
	if _, err := s.applyEarningsSummaryMigration(ctx); err != nil {
		t.Fatal(err)
	}
	assertBackfilledWork(t, s)
}

func TestEarningsSummaryBackfillApplyBeforeOldWriterCommit(t *testing.T) {
	s := seededLegacyEarningsStore(t)
	ctx := context.Background()
	if err := prepareEarningsSummaryBackfill(ctx, s.pool, s.claimEarningsSummaryAttempt); err != nil {
		t.Fatal(err)
	}
	if _, err := s.applyEarningsSummaryMigration(ctx); err != nil {
		t.Fatal(err)
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	executeOldServingCredit(t, tx)
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	assertBackfilledWork(t, s)
}

func TestEarningsSummaryBackfillWaitsForOldWriterWithoutLosingDelta(t *testing.T) {
	s := seededLegacyEarningsStore(t)
	ctx := context.Background()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	executeOldServingCredit(t, tx)
	if err := prepareEarningsSummaryBackfill(ctx, s.pool, s.claimEarningsSummaryAttempt); err != nil {
		t.Fatal(err)
	}
	// Apply while the old transaction still owns its counter locks. A canceled
	// attempt must leave the delta pending for an exact-once retry.
	timed, cancel := context.WithTimeout(ctx, 100*time.Millisecond)
	_, err = s.applyEarningsSummaryMigration(timed)
	cancel()
	if err == nil {
		t.Fatal("expected blocked apply to time out")
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := s.applyEarningsSummaryMigration(ctx); err != nil {
		t.Fatal(err)
	}
	assertBackfilledWork(t, s)
}

func TestBaseRewardEarningPathsExcludeInferenceWork(t *testing.T) {
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			for _, credit := range []bool{false, true} {
				acct := uniqueID("base-acct")
				key := uniqueID("base-key")
				e := &ProviderEarning{AccountID: acct, ProviderKey: key, ProviderID: "p", JobID: uniqueID("base-job"), Model: "base_reward", AmountMicroUSD: 800, PromptTokens: 999, CompletionTokens: 999}
				for i := 0; i < 2; i++ {
					var err error
					if credit {
						err = st.CreditProviderAccount(e)
					} else {
						err = st.RecordProviderEarning(e)
					}
					if err != nil {
						t.Fatal(err)
					}
				}
				accountSummary, err := st.GetAccountEarningsSummary(acct)
				if err != nil {
					t.Fatal(err)
				}
				providerSummary, err := st.GetProviderEarningsSummary(key)
				if err != nil {
					t.Fatal(err)
				}
				for _, summary := range []ProviderEarningsSummary{accountSummary, providerSummary} {
					if summary.Count != 0 || summary.TotalMicroUSD != 800 || summary.PromptTokens != 0 || summary.CompletionTokens != 0 {
						t.Fatalf("base reward counted as work: %+v", summary)
					}
				}
			}
		})
	}
}

func TestEarningsSummaryBackfillAbortedPlanNeverSilentlyReplans(t *testing.T) {
	s := seededLegacyEarningsStore(t)
	ctx := context.Background()
	if _, err := s.pool.Exec(ctx, `ALTER TABLE earnings_summary_backfill_pending ADD CONSTRAINT fail_plan CHECK(key_type <> 'provider')`); err != nil {
		t.Fatal(err)
	}
	if _, err := s.applyEarningsSummaryMigration(ctx); err == nil {
		t.Fatal("expected initial plan failure")
	}
	// The old writer can create a partial summary while the planning attempt is
	// failing. It must not cause a later boot to declare the omitted history done.
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	executeOldServingCredit(t, tx)
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := s.pool.Exec(ctx, `ALTER TABLE earnings_summary_backfill_pending DROP CONSTRAINT fail_plan`); err != nil {
		t.Fatal(err)
	}
	if _, err := s.applyEarningsSummaryMigration(ctx); err == nil {
		t.Fatal("silently replanned after an indeterminate snapshot")
	}
	var done bool
	if err := s.pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE id=$1)`, earningsSummaryMigrationID).Scan(&done); err != nil || done {
		t.Fatalf("incorrect completion: %v %v", done, err)
	}
}

func TestEarningsSummaryBackfillUsesOnePoolConnection(t *testing.T) {
	s := seededLegacyEarningsStore(t)
	cfg := s.pool.Config()
	cfg.MaxConns = 1
	cfg.MinConns = 0
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	single := &PostgresStore{pool: pool}
	if applied, err := single.applyEarningsSummaryMigration(ctx); err != nil || !applied {
		t.Fatalf("single-connection migration: %v %v", applied, err)
	}
}
