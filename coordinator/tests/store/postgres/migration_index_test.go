package postgres_test

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestMigrationsRefuseInvalidStripeRefundIndex(t *testing.T) {
	ctx := context.Background()
	s, err := openPostgresFixture(ctx, store.Config{DatabaseURL: newThrowawayTestDatabase(t)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	pendingFrom(t, s, 9)
	if _, err := s.pool.Exec(ctx, `DROP INDEX idx_ledger_stripe_refund;
		INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
		VALUES ('same-account', 'stripe_payout', -1, 0, 'same-reference'),
		       ('same-account', 'stripe_payout', -1, 0, 'same-reference')`); err != nil {
		t.Fatal(err)
	}
	// A failed real concurrent build leaves the named index invalid.
	if _, err := s.pool.Exec(ctx, `CREATE UNIQUE INDEX CONCURRENTLY idx_ledger_stripe_refund
		ON ledger_entries(account_id, reference)`); err == nil {
		t.Fatal("duplicate rows unexpectedly allowed a unique index")
	}
	if err := s.reopen(ctx); err == nil || !strings.Contains(err.Error(), "index idx_ledger_stripe_refund is invalid") {
		t.Fatalf("reopen with invalid refund index = %v", err)
	}
	var applied bool
	if err := s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM goose_db_version WHERE version_id = 9 AND is_applied)`).Scan(&applied); err != nil {
		t.Fatal(err)
	}
	if applied {
		t.Fatal("invalid refund index migration was recorded as applied")
	}
	// Repair is explicit; the migration does not drop the invalid index itself.
	if _, err := s.pool.Exec(ctx, `DROP INDEX idx_ledger_stripe_refund`); err != nil {
		t.Fatal(err)
	}
	if err := s.reopen(ctx); err != nil {
		t.Fatalf("reopen after explicit repair: %v", err)
	}
	var valid, unique bool
	if err := s.pool.QueryRow(ctx, `SELECT indisvalid AND indisready, indisunique
		FROM pg_index WHERE indexrelid = 'idx_ledger_stripe_refund'::regclass`).Scan(&valid, &unique); err != nil {
		t.Fatal(err)
	}
	if !valid || unique {
		t.Fatalf("repaired refund index valid=%v, unique=%v", valid, unique)
	}
}

// A CREATE INDEX CONCURRENTLY waits for every older snapshot. A query that
// runs longer than the 3 s session lock_timeout must not cancel it: the
// CONCURRENTLY migrations wait up to a minute, and apply on the first attempt.
func TestConcurrentIndexMigrationWaitsForOlderSnapshot(t *testing.T) {
	ctx := context.Background()
	databaseURL := newThrowawayTestDatabase(t)
	s, err := openPostgresFixture(ctx, store.Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatalf("NewPostgres: %v", err)
	}
	t.Cleanup(s.Close)
	if _, err := s.pool.Exec(ctx, `DROP INDEX idx_provider_sessions_account`); err != nil {
		t.Fatal(err)
	}
	pendingFrom(t, s, 10)

	holder := openTestPool(t, databaseURL)
	tx, err := holder.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `SELECT count(*) FROM users`); err != nil {
		t.Fatal(err)
	}
	release := time.AfterFunc(2*migrationLockTimeout, func() { _ = tx.Rollback(context.Background()) })
	defer release.Stop()

	logs := captureLogs(t)
	if err := s.reopen(ctx); err != nil {
		t.Fatalf("migrate behind an older snapshot: %v", err)
	}
	if strings.Contains(logs.String(), "retrying") {
		t.Fatalf("the index build hit the session lock_timeout; logs:\n%s", logs.String())
	}
	if valid, err := indexValid(ctx, s.pool, "idx_provider_sessions_account"); err != nil || !valid {
		t.Fatalf("idx_provider_sessions_account valid=%v err=%v", valid, err)
	}
}

// pendingFrom makes version and every later version pending again.
func pendingFrom(t *testing.T, s *postgresFixture, version int64) {
	t.Helper()
	if _, err := s.pool.Exec(context.Background(), `DELETE FROM `+gooseVersionTable+` WHERE version_id >= $1`, version); err != nil {
		t.Fatal(err)
	}
}

func versionRecorded(t *testing.T, s *postgresFixture, version int64) bool {
	t.Helper()
	var recorded bool
	if err := s.pool.QueryRow(context.Background(), `SELECT EXISTS(SELECT 1 FROM `+gooseVersionTable+` WHERE version_id = $1)`, version).Scan(&recorded); err != nil {
		t.Fatal(err)
	}
	return recorded
}

// indexValid reports pg_index.indisvalid for the index name.
func indexValid(ctx context.Context, pool *pgxpool.Pool, name string) (bool, error) {
	var valid bool
	err := pool.QueryRow(ctx, `SELECT indisvalid FROM pg_index WHERE indexrelid = $1::text::regclass`, name).Scan(&valid)
	return valid, err
}

// An interrupted CONCURRENTLY build leaves an invalid index of the same name.
// The index migration drops it, builds again, and records the version only
// with a valid index.
func TestIndexMigrationRebuildsInvalidLeftover(t *testing.T) {
	ctx := context.Background()
	databaseURL := newThrowawayTestDatabase(t)
	s, err := openPostgresFixture(ctx, store.Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatalf("NewPostgres: %v", err)
	}
	t.Cleanup(s.Close)
	if _, err := s.pool.Exec(ctx, `DROP INDEX idx_provider_sessions_account`); err != nil {
		t.Fatal(err)
	}
	pendingFrom(t, s, 10)

	// The reviewer's reproduction: a build that times out behind an older
	// snapshot fails and leaves an invalid index.
	holder := openTestPool(t, databaseURL)
	tx, err := holder.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `SELECT count(*) FROM users`); err != nil {
		t.Fatal(err)
	}
	builder, err := pgx.Connect(ctx, databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := builder.Exec(ctx, `SET lock_timeout = '200ms'`); err != nil {
		t.Fatal(err)
	}
	if _, err := builder.Exec(ctx, `CREATE INDEX CONCURRENTLY idx_provider_sessions_account ON provider_sessions (account_id)`); err == nil {
		t.Fatal("fixture: the build behind an older snapshot did not fail")
	}
	_ = builder.Close(ctx)
	if err := tx.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	if valid, err := indexValid(ctx, s.pool, "idx_provider_sessions_account"); err != nil || valid {
		t.Fatalf("fixture: leftover index valid=%v err=%v, want an invalid index", valid, err)
	}

	if err := s.reopen(ctx); err != nil {
		t.Fatalf("migrate with an invalid leftover index: %v", err)
	}
	if valid, err := indexValid(ctx, s.pool, "idx_provider_sessions_account"); err != nil || !valid {
		t.Fatalf("idx_provider_sessions_account valid=%v err=%v after migrate", valid, err)
	}
	if !versionRecorded(t, s, 10) {
		t.Fatal("version 10 not recorded after a successful rebuild")
	}
}

// A build that cannot produce a valid index fails the boot, and goose does
// not record the version: here the unique live-user index meets two live
// users with the same Privy ID.
func TestIndexMigrationFailureIsNotRecorded(t *testing.T) {
	ctx := context.Background()
	databaseURL := newThrowawayTestDatabase(t)
	s, err := openPostgresFixture(ctx, store.Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatalf("NewPostgres: %v", err)
	}
	t.Cleanup(s.Close)
	if _, err := s.pool.Exec(ctx, `DROP INDEX idx_users_privy_live`); err != nil {
		t.Fatal(err)
	}
	for _, account := range []string{"first", "second"} {
		if _, err := s.pool.Exec(ctx, `INSERT INTO users (account_id, privy_user_id) VALUES ($1, 'did:privy:shared')`, account); err != nil {
			t.Fatal(err)
		}
	}
	pendingFrom(t, s, 18)

	if err := s.reopen(ctx); err == nil {
		t.Fatal("migrate succeeded although idx_users_privy_live cannot be built")
	}
	if versionRecorded(t, s, 18) {
		t.Fatal("version 18 recorded although its index build failed")
	}
}
