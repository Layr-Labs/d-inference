package store

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"
)

// testPostgresStore returns a PostgresStore connected to the test database.
// It skips the test if DATABASE_URL is not set.
// Each test gets a clean slate by truncating all tables.
func testPostgresStore(t *testing.T) *PostgresStore {
	t.Helper()

	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		t.Skip("DATABASE_URL not set — skipping PostgreSQL integration test")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	s, err := NewPostgres(ctx, Config{DatabaseURL: dbURL})
	if err != nil {
		t.Fatalf("NewPostgres: %v", err)
	}

	// Clean tables for test isolation.
	for _, table := range []string{
		"usage",
		"payments",
		"api_keys",
		"balances",
		"ledger_entries",
		"billing_sessions",
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
		"provider_sessions",
		"inference_routes",
		"request_rejections",
		"provider_trust_reuse",
		"provider_floor_draws",
		"code_attestations",
	} {
		if _, err := s.pool.Exec(ctx, "TRUNCATE "+table+" CASCADE"); err != nil {
			t.Fatalf("truncate %s: %v", table, err)
		}
	}

	t.Cleanup(func() { s.Close() })
	return s
}

// Compile-time interface checks (replace the old TestMemoryStoreImplementsInterface
// and TestPostgresStoreImplementsInterface runtime tests).
var (
	_ Store = (*MemoryStore)(nil)
	_ Store = (*PostgresStore)(nil)
)

// storeBackends returns the store impls to exercise. MemoryStore always runs;
// PostgresStore runs only when DATABASE_URL is set (throwaway test DB).
func storeBackends(t *testing.T) map[string]Store {
	t.Helper()
	backends := map[string]Store{"memory": NewMemory(Config{})}
	if os.Getenv("DATABASE_URL") != "" {
		backends["postgres"] = testPostgresStore(t)
	}
	return backends
}

var idSeq int64

// uniqueID returns a process-unique identifier with the given prefix so the
// memory and postgres variants never collide across sub-tests.
func uniqueID(prefix string) string {
	idSeq++
	return fmt.Sprintf("%s-%d-%d", prefix, time.Now().UnixNano(), idSeq)
}

func mustBalance(t testing.TB, s LedgerStore, accountID string) int64 {
	t.Helper()
	balance, err := s.GetBalance(accountID)
	if err != nil {
		t.Fatalf("get balance for %q: %v", accountID, err)
	}
	return balance
}

func mustWithdrawableBalance(t testing.TB, s LedgerStore, accountID string) int64 {
	t.Helper()
	balance, err := s.GetWithdrawableBalance(accountID)
	if err != nil {
		t.Fatalf("get withdrawable balance for %q: %v", accountID, err)
	}
	return balance
}

func mustBalances(t testing.TB, s LedgerStore, accountID string) (int64, int64) {
	t.Helper()
	balance, withdrawable, err := s.GetBalanceWithWithdrawable(accountID)
	if err != nil {
		t.Fatalf("get balances for %q: %v", accountID, err)
	}
	return balance, withdrawable
}

func mustLedgerHistory(t testing.TB, s LedgerStore, accountID string) []LedgerEntry {
	t.Helper()
	history, err := s.LedgerHistory(accountID)
	if err != nil {
		t.Fatalf("get ledger history for %q: %v", accountID, err)
	}
	return history
}
