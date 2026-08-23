package store

import (
	"context"
	"fmt"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// testPostgresStore returns a PostgresStore connected to the shared test
// database. It skips the test if DATABASE_URL is not set.
//
// PostgreSQL contract tests are serialized because they reset shared tables;
// callers must not mark a test that uses this helper parallel. The reset covers
// all application data tables. Migration markers are retained so a contract
// test cannot make a later NewPostgres call replay a one-time migration over
// another test's data.
func testPostgresStore(t *testing.T) *PostgresStore {
	t.Helper()

	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		t.Skip("DATABASE_URL not set — skipping PostgreSQL integration test")
	}

	postgresTestMu.Lock()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	s, err := NewPostgres(ctx, Config{DatabaseURL: dbURL})
	if err != nil {
		postgresTestMu.Unlock()
		t.Fatalf("NewPostgres: %v", err)
	}

	if _, err := s.pool.Exec(ctx, "TRUNCATE "+strings.Join(postgresContractTables, ", ")+" RESTART IDENTITY CASCADE"); err != nil {
		s.Close()
		postgresTestMu.Unlock()
		t.Fatalf("reset PostgreSQL contract tables: %v", err)
	}

	t.Cleanup(func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cleanupCancel()
		_, cleanupErr := s.pool.Exec(cleanupCtx, "TRUNCATE "+strings.Join(postgresContractTables, ", ")+" RESTART IDENTITY CASCADE")
		s.Close()
		postgresTestMu.Unlock()
		if cleanupErr != nil {
			t.Errorf("clean PostgreSQL contract tables: %v", cleanupErr)
		}
	})
	return s
}

// Compile-time interface checks (replace the old TestMemoryStoreImplementsInterface
// and TestPostgresStoreImplementsInterface runtime tests).
var (
	_ Store = (*MemoryStore)(nil)
	_ Store = (*PostgresStore)(nil)
)

// storeBackends returns the store implementations to exercise. MemoryStore
// always runs. When DATABASE_URL is unavailable it registers an explicit
// postgres subtest skip so every shared contract reports both backend variants
// instead of silently omitting PostgreSQL coverage.
//
// PostgreSQL contract tests are serialized by testPostgresStore; callers must
// not mark the returned subtests parallel.
func storeBackends(t *testing.T) map[string]Store {
	t.Helper()
	backends := map[string]Store{"memory": NewMemory(Config{})}
	if os.Getenv("DATABASE_URL") == "" {
		t.Run("postgres", func(t *testing.T) {
			t.Skip("DATABASE_URL not set — skipping PostgreSQL integration test")
		})
		return backends
	}
	backends["postgres"] = testPostgresStore(t)
	return backends
}

var (
	postgresTestMu sync.Mutex
	idSeq          atomic.Uint64
)

// Keep this list exhaustive for application tables created by PostgresStore.
// schema_migrations is deliberately excluded; see testPostgresStore.
var postgresContractTables = []string{
	"model_active_versions",
	"model_version_files",
	"model_versions",
	"model_registry",
	"publishing_api_keys",
	"model_aliases",
	"releases",
	"model_prices",
	"provider_reputation",
	"provider_log_reports",
	"provider_sessions",
	"provider_floor_draws",
	"provider_trust_reuse",
	"code_attestations",
	"request_rejections",
	"inference_routes",
	"stripe_withdrawals",
	"provider_payouts",
	"earnings_summary",
	"provider_earnings",
	"invite_redemptions",
	"invite_codes",
	"provider_tokens",
	"device_codes",
	"billing_sessions",
	"referrals",
	"referrers",
	"ledger_entries",
	"balances",
	"payments",
	"usage_totals",
	"usage",
	"api_keys",
	"users",
	"providers",
}

// uniqueID returns a process-unique identifier with the given prefix so the
// memory and postgres variants never collide across sub-tests.
func uniqueID(prefix string) string {
	return fmt.Sprintf("%s-%d-%d", prefix, time.Now().UnixNano(), idSeq.Add(1))
}
