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
			t.Fatalf("DAR-349 regression: boot-time provider_earnings dedupe reintroduced "+
				"(found %q in postgres.go); move destructive cleanup to an offline job", banned)
		}
	}
}

// TestProviderEarningsJobIndex_BootSafe verifies the safe replacement: startup
// builds a valid partial unique index on provider_earnings(job_id) without a
// dedupe DELETE, migrate() is re-entrant, and the index backs the idempotent
// ON CONFLICT write path. Runs only with DATABASE_URL (throwaway test DB).
func TestProviderEarningsJobIndex_BootSafe(t *testing.T) {
	s := testPostgresStore(t) // t.Skip()s when DATABASE_URL is unset
	ctx := context.Background()

	// NewPostgres -> migrate -> ensureProviderEarningsJobIndex left a VALID index.
	if !jobIndexValid(t, s) {
		t.Fatal("idx_provider_earnings_job missing or invalid after startup")
	}

	// Re-entrancy: a coordinator restart re-runs migrate() and must not error or
	// do heavy work (the valid-index fast path makes index creation a no-op).
	if err := s.migrate(ctx); err != nil {
		t.Fatalf("re-running migrate (restart): %v", err)
	}
	if !jobIndexValid(t, s) {
		t.Fatal("idx_provider_earnings_job invalid after re-running migrate")
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
