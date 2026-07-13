package store

import (
	"bytes"
	"context"
	"os"
	"testing"
)

// TestMigrate_NoBootTimeProviderEarningsDedupe is the always-on (no-DB) guard for
// DAR-349: a boot-time `DELETE ... GROUP BY job_id` on the hot provider_earnings
// table once held a relation lock for ~15m and stopped the coordinator from
// binding :8080 (production outage). It must never return to the startup
// migration path. Dedupe, if ever needed, is an offline job
// (coordinator/store/migrations/dedupe_provider_earnings.sql).
func TestMigrate_NoBootTimeProviderEarningsDedupe(t *testing.T) {
	src, err := os.ReadFile("postgres.go")
	if err != nil {
		t.Fatalf("read postgres.go: %v", err)
	}
	for _, banned := range []string{
		"DELETE FROM provider_earnings WHERE id NOT IN",
		"GROUP BY job_id) AND job_id",
	} {
		if bytes.Contains(src, []byte(banned)) {
			t.Fatalf("DAR-349 regression: serving startup provider_earnings dedupe reintroduced "+
				"(found %q in postgres.go); keep destructive cleanup in the offline job", banned)
		}
	}
}

func TestMigrate_NoWithdrawableBalanceBackfill(t *testing.T) {
	src, err := os.ReadFile("postgres.go")
	if err != nil {
		t.Fatalf("read postgres.go: %v", err)
	}
	if bytes.Contains(src, []byte("UPDATE balances b SET withdrawable_micro_usd")) {
		t.Fatal("unsafe withdrawable reconstruction returned to serving startup; use the offline reconciliation report")
	}
}

func TestMigrate_DoesNotReclassifyLaterDepositsAsWithdrawable(t *testing.T) {
	s := testPostgresStore(t)
	accountID := uniqueID("withdrawable-restart")
	if err := s.CreditWithdrawable(accountID, 100_000, LedgerPayout, "earned"); err != nil {
		t.Fatal(err)
	}
	if err := s.DebitWithdrawable(accountID, 100_000, LedgerStripePayout, "withdrawn"); err != nil {
		t.Fatal(err)
	}
	if err := s.Credit(accountID, 50_000, LedgerStripeDeposit, "later-deposit"); err != nil {
		t.Fatal(err)
	}
	reopened, err := NewPostgres(context.Background(), Config{DatabaseURL: os.Getenv("DATABASE_URL")})
	if err != nil {
		t.Fatal(err)
	}
	reopened.Close()
	balance, withdrawable := s.GetBalanceWithWithdrawable(accountID)
	if balance != 50_000 || withdrawable != 0 {
		t.Fatalf("restart changed balance provenance: total=%d withdrawable=%d, want 50000/0", balance, withdrawable)
	}
}

// TestProviderEarningsJobIndex_BootSafe verifies the safe replacement: the
// deployment migration builds a valid partial unique index without a dedupe
// DELETE, migration application is re-entrant, and the index backs the idempotent
// ON CONFLICT write path. Runs only with DATABASE_URL (throwaway test DB).
func TestProviderEarningsJobIndex_BootSafe(t *testing.T) {
	s := testPostgresStore(t) // t.Skip()s when DATABASE_URL is unset
	ctx := context.Background()

	// The test harness migration left a VALID index.
	if !jobIndexValid(t, s) {
		t.Fatal("idx_provider_earnings_job missing or invalid after migration")
	}

	// Re-entrancy: a repeated deployment migration has no pending work.
	result, err := ApplyPostgresMigrations(ctx, os.Getenv("DATABASE_URL"), MigrationOptions{})
	if err != nil {
		t.Fatalf("re-running migrations: %v", err)
	}
	if len(result.Applied) != 0 {
		t.Fatalf("re-running migrations applied versions %v, want none", result.Applied)
	}
	if !jobIndexValid(t, s) {
		t.Fatal("idx_provider_earnings_job invalid after re-running migrations")
	}

	// RecordProviderEarning is idempotent for a non-empty job_id (ON CONFLICT
	// needs the partial unique index to exist — which it now does).
	job := uniqueID("job")
	for i := 0; i < 2; i++ {
		e := &ProviderEarning{
			AccountID: uniqueID("acct"), ProviderID: "p", ProviderKey: uniqueID("pk"),
			JobID: job, Model: "m", AmountMicroUSD: 1000, PromptTokens: 1, CompletionTokens: 2,
		}
		if err := s.RecordProviderEarning(e); err != nil {
			t.Fatalf("record earning %d: %v", i, err)
		}
	}
	if n := countEarningsByJob(t, s, job); n != 1 {
		t.Fatalf("rows for job %q = %d, want 1 (idempotent)", job, n)
	}

	// Empty job_id is excluded from the partial index, so multiple rows are kept.
	for i := 0; i < 2; i++ {
		e := &ProviderEarning{
			AccountID: uniqueID("acct"), ProviderID: "p", ProviderKey: uniqueID("pk"),
			JobID: "", Model: "m", AmountMicroUSD: 1000, PromptTokens: 1, CompletionTokens: 2,
		}
		if err := s.RecordProviderEarning(e); err != nil {
			t.Fatalf("record empty-job earning %d: %v", i, err)
		}
	}
	if n := countEarningsByJob(t, s, ""); n != 2 {
		t.Fatalf("rows for empty job_id = %d, want 2 (partial index excludes '')", n)
	}
}

func jobIndexValid(t *testing.T, s *PostgresStore) bool {
	t.Helper()
	var valid bool
	if err := s.pool.QueryRow(context.Background(), `
		SELECT COALESCE((
			SELECT i.indisvalid FROM pg_class c JOIN pg_index i ON i.indexrelid = c.oid
			WHERE c.relname = 'idx_provider_earnings_job'
		), false)`).Scan(&valid); err != nil {
		t.Fatalf("check idx_provider_earnings_job: %v", err)
	}
	return valid
}

func countEarningsByJob(t *testing.T, s *PostgresStore, job string) int {
	t.Helper()
	var n int
	if err := s.pool.QueryRow(context.Background(),
		`SELECT count(*) FROM provider_earnings WHERE job_id = $1`, job).Scan(&n); err != nil {
		t.Fatalf("count earnings: %v", err)
	}
	return n
}
