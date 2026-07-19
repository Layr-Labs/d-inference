package store

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var withdrawableTestDatabaseSequence atomic.Uint64

func newWithdrawableTestDatabase(t *testing.T) string {
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

	databaseName := fmt.Sprintf("dinf_withdrawable_%d_%d",
		time.Now().UnixNano(), withdrawableTestDatabaseSequence.Add(1))
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

func newWithdrawableMigrationStore(t *testing.T, databaseURL string) *PostgresStore {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		t.Fatalf("open migration store: %v", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		t.Fatalf("ping migration store: %v", err)
	}
	t.Cleanup(pool.Close)
	return &PostgresStore{
		pool:       pool,
		priceCache: make(map[string]cachedPrice),
	}
}

func prepareWithdrawableMigrationSchema(t *testing.T, s *PostgresStore, withWithdrawableColumn bool) {
	t.Helper()
	balanceColumns := `
		account_id TEXT PRIMARY KEY,
		balance_micro_usd BIGINT NOT NULL DEFAULT 0,
		updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`
	if withWithdrawableColumn {
		balanceColumns = `
			account_id TEXT PRIMARY KEY,
			balance_micro_usd BIGINT NOT NULL DEFAULT 0,
			withdrawable_micro_usd BIGINT NOT NULL DEFAULT 0,
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`
	}
	for _, statement := range []string{
		`CREATE TABLE schema_migrations (
			id TEXT PRIMARY KEY,
			applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE TABLE balances (` + balanceColumns + `)`,
		`CREATE TABLE ledger_entries (
			id BIGSERIAL PRIMARY KEY,
			account_id TEXT NOT NULL,
			entry_type TEXT NOT NULL,
			amount_micro_usd BIGINT NOT NULL,
			balance_after BIGINT NOT NULL,
			reference TEXT NOT NULL DEFAULT '',
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
	} {
		if _, err := s.pool.Exec(context.Background(), statement); err != nil {
			t.Fatalf("prepare migration schema: %v\n%s", err, statement)
		}
	}
}

func seedMigrationBalance(t *testing.T, s *PostgresStore, accountID string, balance int64, withdrawable *int64) {
	t.Helper()
	var err error
	if withdrawable == nil {
		_, err = s.pool.Exec(context.Background(),
			`INSERT INTO balances (account_id, balance_micro_usd) VALUES ($1, $2)`,
			accountID, balance)
	} else {
		_, err = s.pool.Exec(context.Background(),
			`INSERT INTO balances (account_id, balance_micro_usd, withdrawable_micro_usd) VALUES ($1, $2, $3)`,
			accountID, balance, *withdrawable)
	}
	if err != nil {
		t.Fatalf("seed balance %q: %v", accountID, err)
	}
}

func seedMigrationLedger(
	t *testing.T,
	s *PostgresStore,
	accountID string,
	entryType LedgerEntryType,
	amount int64,
	balanceAfter int64,
	reference string,
) {
	t.Helper()
	if _, err := s.pool.Exec(context.Background(), `
		INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
		VALUES ($1, $2, $3, $4, $5)`,
		accountID, string(entryType), amount, balanceAfter, reference); err != nil {
		t.Fatalf("seed ledger %q/%q: %v", accountID, entryType, err)
	}
}

func migrationWithdrawableBalance(t *testing.T, s *PostgresStore, accountID string) int64 {
	t.Helper()
	var amount int64
	if err := s.pool.QueryRow(context.Background(),
		`SELECT withdrawable_micro_usd FROM balances WHERE account_id = $1`,
		accountID).Scan(&amount); err != nil {
		t.Fatalf("read withdrawable balance %q: %v", accountID, err)
	}
	return amount
}

func migrationMarker(t *testing.T, s *PostgresStore) (count int, appliedAt time.Time) {
	t.Helper()
	if err := s.pool.QueryRow(context.Background(),
		`SELECT COUNT(*) FROM schema_migrations WHERE id = $1`,
		withdrawableBalanceMigrationID).Scan(&count); err != nil {
		t.Fatalf("read migration marker: %v", err)
	}
	if count == 1 {
		if err := s.pool.QueryRow(context.Background(),
			`SELECT applied_at FROM schema_migrations WHERE id = $1`,
			withdrawableBalanceMigrationID).Scan(&appliedAt); err != nil {
			t.Fatalf("read migration applied_at: %v", err)
		}
	}
	return count, appliedAt
}
