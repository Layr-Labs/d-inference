package store

import (
	"context"
	"sync"
	"testing"
	"time"
)

func earningsMigrationFixture(t *testing.T) *PostgresStore {
	t.Helper()
	s := newWithdrawableMigrationStore(t, newWithdrawableTestDatabase(t))
	for _, q := range []string{
		`CREATE TABLE schema_migrations(id TEXT PRIMARY KEY, applied_at TIMESTAMPTZ DEFAULT NOW())`,
		`CREATE TABLE provider_earnings(account_id TEXT,provider_key TEXT,amount_micro_usd BIGINT,prompt_tokens INT,completion_tokens INT,model TEXT)`,
		`CREATE TABLE earnings_summary(key TEXT,key_type TEXT,total_count BIGINT,total_micro_usd BIGINT,total_prompt_tokens BIGINT,total_completion_tokens BIGINT,updated_at TIMESTAMPTZ,PRIMARY KEY(key,key_type))`,
		earningsSummaryBackfillPendingDDL,
		`INSERT INTO provider_earnings VALUES ('a','p',100,20,30,'m'),('a','p',200,40,50,'m')`,
	} {
		if _, err := s.pool.Exec(context.Background(), q); err != nil {
			t.Fatal(err)
		}
	}
	return s
}

func TestEarningsSummaryMigrationOncePreservesLiveTotalsAndSkipsLockedHistory(t *testing.T) {
	s := earningsMigrationFixture(t)
	ctx := context.Background()
	// An existing live counter must not be overwritten even if historical
	// records differ (pruning, retention and prior accounting can differ).
	if _, err := s.pool.Exec(ctx, `INSERT INTO earnings_summary VALUES ('a','account',9,999,80,90,NOW())`); err != nil {
		t.Fatal(err)
	}
	applied, err := s.applyEarningsSummaryMigration(ctx)
	if err != nil || !applied {
		t.Fatalf("first: %v %v", applied, err)
	}
	var money int64
	if err := s.pool.QueryRow(ctx, `SELECT total_micro_usd FROM earnings_summary WHERE key='a' AND key_type='account'`).Scan(&money); err != nil || money != 999 {
		t.Fatalf("existing: %d %v", money, err)
	}
	if err := s.pool.QueryRow(ctx, `SELECT total_micro_usd FROM earnings_summary WHERE key='p' AND key_type='provider'`).Scan(&money); err != nil || money != 300 {
		t.Fatalf("backfilled: %d %v", money, err)
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `LOCK TABLE provider_earnings IN ACCESS EXCLUSIVE MODE`); err != nil {
		t.Fatal(err)
	}
	timed, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	applied, err = s.applyEarningsSummaryMigration(timed)
	if err != nil || applied {
		t.Fatalf("restart touched history: %v %v", applied, err)
	}
}

func TestEarningsSummaryMigrationResumesCommittedProgressWithoutDoubleCount(t *testing.T) {
	s := earningsMigrationFixture(t)
	ctx := context.Background()
	if _, err := s.pool.Exec(ctx, `ALTER TABLE earnings_summary ADD CONSTRAINT fail_provider CHECK(key_type <> 'provider')`); err != nil {
		t.Fatal(err)
	}
	if _, err := s.applyEarningsSummaryMigration(ctx); err == nil {
		t.Fatal("expected failure")
	}
	var accountMoney int64
	if err := s.pool.QueryRow(ctx, `SELECT total_micro_usd FROM earnings_summary WHERE key='a' AND key_type='account'`).Scan(&accountMoney); err != nil || accountMoney != 300 {
		t.Fatalf("committed account progress: %d %v", accountMoney, err)
	}
	var finalMarker bool
	if err := s.pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE id=$1)`, earningsSummaryMigrationID).Scan(&finalMarker); err != nil || finalMarker {
		t.Fatalf("premature marker: %v %v", finalMarker, err)
	}
	// History becomes unavailable after the plan commit: retry must use only
	// the durable pending delta and must not double-add the completed account.
	if _, err := s.pool.Exec(ctx, `ALTER TABLE earnings_summary DROP CONSTRAINT fail_provider; DROP TABLE provider_earnings`); err != nil {
		t.Fatal(err)
	}
	if applied, err := s.applyEarningsSummaryMigration(ctx); err != nil || !applied {
		t.Fatalf("retry: %v %v", applied, err)
	}
	for _, key := range []string{"a", "p"} {
		var money int64
		if err := s.pool.QueryRow(ctx, `SELECT total_micro_usd FROM earnings_summary WHERE key=$1`, key).Scan(&money); err != nil || money != 300 {
			t.Fatalf("resumed %s: %d %v", key, money, err)
		}
	}
}

func TestEarningsSummaryMigrationConcurrentClaims(t *testing.T) {
	s := earningsMigrationFixture(t)
	var wg sync.WaitGroup
	type outcome struct {
		applied bool
		err     error
	}
	results := make(chan outcome, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			a, e := s.applyEarningsSummaryMigration(context.Background())
			results <- outcome{a, e}
		}()
	}
	wg.Wait()
	close(results)
	applied := 0
	for result := range results {
		if result.err != nil {
			t.Fatal(result.err)
		}
		if result.applied {
			applied++
		}
	}
	if applied != 1 {
		t.Fatalf("applied %d times", applied)
	}
}

func TestRecordProviderEarningMaintainsSummaryWithoutRestart(t *testing.T) {
	s := testPostgresStore(t)
	e := &ProviderEarning{AccountID: uniqueID("account"), ProviderKey: uniqueID("key"), ProviderID: "p", JobID: uniqueID("job"), Model: "m", AmountMicroUSD: 100, PromptTokens: 20, CompletionTokens: 30}
	for i := 0; i < 2; i++ {
		if err := s.RecordProviderEarning(e); err != nil {
			t.Fatal(err)
		}
	}
	for _, key := range []string{e.AccountID, e.ProviderKey} {
		var count, money, prompt, completion int64
		if err := s.pool.QueryRow(context.Background(), `SELECT total_count,total_micro_usd,total_prompt_tokens,total_completion_tokens FROM earnings_summary WHERE key=$1`, key).Scan(&count, &money, &prompt, &completion); err != nil {
			t.Fatal(err)
		}
		if count != 1 || money != 100 || prompt != 20 || completion != 30 {
			t.Fatalf("summary doubled/lost: %d %d %d %d", count, money, prompt, completion)
		}
	}
	var balanceRows int
	if err := s.pool.QueryRow(context.Background(), `SELECT count(*) FROM balances WHERE account_id=$1`, e.AccountID).Scan(&balanceRows); err != nil || balanceRows != 0 {
		t.Fatalf("record-only unexpectedly credited balance: %d %v", balanceRows, err)
	}
}
