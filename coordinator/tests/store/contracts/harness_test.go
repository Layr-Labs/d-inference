package store_test

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/eigeninference/d-inference/coordinator/store/postgres"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// testPostgresStore returns a PostgresStore connected to the test database.
// It skips the test if DATABASE_URL is not set.
// Each test gets a clean slate by truncating all tables.
func testPostgresStore(t testing.TB) *postgres.PostgresStore {
	t.Helper()

	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		t.Skip("DATABASE_URL not set — skipping PostgreSQL integration test")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	s, err := postgres.NewPostgres(ctx, store.Config{DatabaseURL: dbURL})
	if err != nil {
		t.Fatalf("NewPostgres: %v", err)
	}

	t.Cleanup(func() { s.Close() })
	cleanupPool, err := pgxpool.New(ctx, dbURL)
	if err != nil {
		t.Fatalf("connect cleanup pool: %v", err)
	}
	defer cleanupPool.Close()

	// Clean tables within this test process's isolated database.
	for _, table := range []string{
		"consumer_charge_settlements",
		"model_token_provider_carries",
		"model_token_reservations",
		"model_token_grants",
		"model_token_promotions",
		"usage",
		"payments",
		"api_keys",
		"balances",
		"ledger_entries",
		"billing_sessions",
		"small_models_interest",
		"users",
		"device_codes",
		"provider_tokens",
		"invite_redemptions",
		"invite_codes",
		"referrals",
		"referrers",
		"provider_earnings",
		"provider_payouts",
		"providers",
		"stripe_withdrawals",
		"global_payout_withdrawals",
		"global_payout_recipients",
		"provider_sessions",
		"inference_routes",
		"request_rejections",
		"request_outcomes",
		"model_demand_requests",
		"model_demand_hourly",
		"provider_trust_reuse",
		"legacy_mdm_cohort",
		"legacy_mdm_cohort_freeze",
		"provider_floor_draws",
		"code_attestations",
		"code_attest_push_budgets",
		"app_attest_build_qualifications",
		"app_attest_key_rotations",
		"app_attest_shadow_keys",
		"app_attest_enrollments",
		"app_attest_receipts",
		"app_attest_evidence",
		"darkbloom_machines",
		"darkbloom_machine_observations",
		"app_attest_shadow_events",
		"request_profiles",
		"fleet_snapshots",
		"erasure_outbox",
		"erasure_requests",
	} {
		if _, err := cleanupPool.Exec(ctx, "TRUNCATE "+table+" CASCADE"); err != nil {
			t.Fatalf("truncate %s: %v", table, err)
		}
	}

	return s
}

// storeBackends returns the store impls to exercise. MemoryStore always runs;
// PostgresStore runs only when DATABASE_URL is set (throwaway test DB).
func storeBackends(t *testing.T) map[string]store.Store {
	t.Helper()
	backends := map[string]store.Store{"memory": memory.NewMemory(store.Config{})}
	if os.Getenv("DATABASE_URL") != "" {
		backends["postgres"] = testPostgresStore(t)
	}
	return backends
}

var idSeq atomic.Uint64

// uniqueID returns a process-unique identifier with the given prefix so the
// memory and postgres variants never collide across sub-tests.
func uniqueID(prefix string) string {
	return fmt.Sprintf("%s-%d-%d", prefix, time.Now().UnixNano(), idSeq.Add(1))
}

// newThrowawayTestDatabase creates an empty database on the DATABASE_URL
// server, returns its URL and drops it at cleanup. Tests that must boot
// NewPostgres against a fresh schema use it instead of the shared database.
var throwawayTestDatabaseSequence atomic.Uint64

func newThrowawayTestDatabase(t *testing.T) string {
	t.Helper()

	sourceURL := os.Getenv("DATABASE_URL")
	if sourceURL == "" {
		t.Skip("DATABASE_URL not set — skipping PostgreSQL integration test")
	}
	targetURL, err := url.Parse(sourceURL)
	if err != nil {
		t.Fatalf("parse database URL: %v", err)
	}
	if targetURL.Scheme == "" || targetURL.Host == "" {
		t.Fatalf("DATABASE_URL must be a PostgreSQL URL for isolated database tests")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	admin, err := pgxpool.New(ctx, sourceURL)
	if err != nil {
		t.Fatalf("connect database server: %v", err)
	}

	databaseName := fmt.Sprintf("dinf_throwaway_%d_%d",
		time.Now().UnixNano(), throwawayTestDatabaseSequence.Add(1))
	quotedDatabase := pgx.Identifier{databaseName}.Sanitize()
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+quotedDatabase+" TEMPLATE template0"); err != nil {
		admin.Close()
		t.Fatalf("create isolated throwaway database: %v", err)
	}

	targetURL.Path = "/" + databaseName

	t.Cleanup(func() {
		dropCtx, dropCancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer dropCancel()
		if _, err := admin.Exec(dropCtx, "DROP DATABASE "+quotedDatabase+" WITH (FORCE)"); err != nil {
			t.Errorf("drop isolated throwaway database: %v", err)
		}
		admin.Close()
	})
	return targetURL.String()
}
