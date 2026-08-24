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

func TestProviderEarningsIndexRecoveryNeverUsesBlockingDrop(t *testing.T) {
	src, err := os.ReadFile("postgres.go")
	if err != nil {
		t.Fatalf("read postgres.go: %v", err)
	}
	if bytes.Contains(src, []byte("DROP INDEX IF EXISTS")) {
		t.Fatal("provider earnings index recovery uses table-blocking DROP INDEX")
	}
	if !bytes.Contains(src, []byte("DROP INDEX CONCURRENTLY IF EXISTS")) {
		t.Fatal("provider earnings index recovery must drop interrupted builds concurrently")
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

func TestEarningsMarketIndexesBootSafe(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	indexes := []string{
		"idx_usage_request_public_model",
		"idx_provider_earnings_market_window",
	}
	for _, name := range indexes {
		if !postgresIndexValid(t, s, name) {
			t.Fatalf("%s missing or invalid after startup", name)
		}
	}
	if err := s.migrate(ctx); err != nil {
		t.Fatalf("re-running migrate (restart): %v", err)
	}
	for _, name := range indexes {
		if !postgresIndexValid(t, s, name) {
			t.Fatalf("%s invalid after re-running migrate", name)
		}
	}
}

func TestDropInvalidIndexConcurrently(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	const indexName = "idx_provider_earnings_invalid_recovery_test"
	t.Cleanup(func() {
		_ = s.dropInvalidIndexConcurrently(context.Background(), indexName)
	})

	for i := range 2 {
		if err := s.RecordProviderEarning(&ProviderEarning{
			AccountID:      uniqueID("acct"),
			ProviderID:     "provider",
			ProviderKey:    uniqueID("key"),
			JobID:          uniqueID("job"),
			Model:          "duplicate-model",
			AmountMicroUSD: int64(1_000 + i),
		}); err != nil {
			t.Fatalf("seed duplicate model %d: %v", i, err)
		}
	}

	conn, err := s.pool.Acquire(ctx)
	if err != nil {
		t.Fatalf("acquire connection: %v", err)
	}
	mrr := conn.Conn().PgConn().Exec(ctx,
		`CREATE UNIQUE INDEX CONCURRENTLY `+indexName+` ON provider_earnings(model)`)
	_, createErr := mrr.ReadAll()
	conn.Release()
	if createErr == nil {
		t.Fatal("duplicate data unexpectedly produced a valid unique index")
	}

	var exists, valid bool
	if err := s.pool.QueryRow(ctx, `
		SELECT true, i.indisvalid
		FROM pg_class c JOIN pg_index i ON i.indexrelid = c.oid
		WHERE c.relname = $1`, indexName).Scan(&exists, &valid); err != nil {
		t.Fatalf("read failed concurrent index: %v", err)
	}
	if !exists || valid {
		t.Fatalf("failed build state = exists:%t valid:%t, want true/false", exists, valid)
	}

	if err := s.dropInvalidIndexConcurrently(ctx, indexName); err != nil {
		t.Fatalf("drop invalid index concurrently: %v", err)
	}
	if err := s.pool.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM pg_class WHERE relname = $1)`,
		indexName,
	).Scan(&exists); err != nil {
		t.Fatalf("check dropped index: %v", err)
	}
	if exists {
		t.Fatal("invalid index still exists after concurrent recovery")
	}
}

func jobIndexValid(t *testing.T, s *PostgresStore) bool {
	return postgresIndexValid(t, s, "idx_provider_earnings_job")
}

func postgresIndexValid(t *testing.T, s *PostgresStore, name string) bool {
	t.Helper()
	var valid bool
	if err := s.pool.QueryRow(context.Background(), `
		SELECT COALESCE((
			SELECT i.indisvalid FROM pg_class c JOIN pg_index i ON i.indexrelid = c.oid
			WHERE c.relname = $1
		), false)`, name).Scan(&valid); err != nil {
		t.Fatalf("check %s: %v", name, err)
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
