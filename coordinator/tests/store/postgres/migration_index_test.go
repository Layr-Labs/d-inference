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

// An interrupted build must survive retries unchanged until an operator repairs
// it. Exercise both the newer migrations and the legacy earnings unique index.
func TestIndexMigrationPreservesInvalidLeftover(t *testing.T) {
	for _, tc := range []struct {
		name    string
		version int64
		ddl     string
	}{
		{"idx_provider_sessions_account", 10, `CREATE INDEX CONCURRENTLY idx_provider_sessions_account ON provider_sessions (account_id)`},
		{"idx_provider_earnings_job", 4, `CREATE UNIQUE INDEX CONCURRENTLY idx_provider_earnings_job ON provider_earnings(job_id) WHERE job_id <> ''`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			testIndexMigrationPreservesInvalidLeftover(t, tc.name, tc.version, tc.ddl)
		})
	}
}

func testIndexMigrationPreservesInvalidLeftover(t *testing.T, name string, version int64, ddl string) {
	ctx := context.Background()
	databaseURL := newThrowawayTestDatabase(t)
	s, err := openPostgresFixture(ctx, store.Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatalf("NewPostgres: %v", err)
	}
	t.Cleanup(s.Close)
	if _, err := s.pool.Exec(ctx, `DROP INDEX `+pgx.Identifier{name}.Sanitize()); err != nil {
		t.Fatal(err)
	}
	pendingFrom(t, s, version)

	// The reviewer's reproduction: a build that times out behind an older
	// snapshot fails and leaves an invalid index.
	holder := openTestPool(t, databaseURL)
	tx, err := holder.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SELECT count(*) FROM users`); err != nil {
		t.Fatal(err)
	}
	builder, err := pgx.Connect(ctx, databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	defer builder.Close(ctx)
	if _, err := builder.Exec(ctx, `SET lock_timeout = '200ms'`); err != nil {
		t.Fatal(err)
	}
	if _, err := builder.Exec(ctx, ddl); err == nil {
		t.Fatal("fixture: the build behind an older snapshot did not fail")
	}
	_ = builder.Close(ctx)
	if err := tx.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	if valid, err := indexValid(ctx, s.pool, name); err != nil || valid {
		t.Fatalf("fixture: leftover index valid=%v err=%v, want an invalid index", valid, err)
	}
	before := queryLines(t, s.pool, `SELECT indexrelid::text || ' ' || pg_get_indexdef(indexrelid) FROM pg_index WHERE indexrelid = '`+name+`'::regclass`)

	for attempt := range 2 {
		err := s.reopen(ctx)
		for _, hint := range []string{name, "preserved without changes", "pg_stat_progress_create_index", "pg_stat_activity", "operator"} {
			if err == nil || !strings.Contains(err.Error(), hint) {
				t.Fatalf("attempt %d: error = %v, want actionable hint %q", attempt, err, hint)
			}
		}
		if valid, err := indexValid(ctx, s.pool, name); err != nil || valid {
			t.Fatalf("%s valid=%v err=%v after migration refusal", name, valid, err)
		}
		assertSameLines(t, "invalid index before", before, "after refusal", queryLines(t, s.pool,
			`SELECT indexrelid::text || ' ' || pg_get_indexdef(indexrelid) FROM pg_index WHERE indexrelid = '`+name+`'::regclass`))
		if versionRecorded(t, s, version) {
			t.Fatalf("version %d recorded despite invalid index", version)
		}
	}
	// Only an explicit operator repair permits the migration to proceed.
	if _, err := s.pool.Exec(ctx, `DROP INDEX `+pgx.Identifier{name}.Sanitize()); err != nil {
		t.Fatal(err)
	}
	if err := s.reopen(ctx); err != nil {
		t.Fatalf("migrate after explicit repair: %v", err)
	}
	if valid, err := indexValid(ctx, s.pool, name); err != nil || !valid || !versionRecorded(t, s, version) {
		t.Fatalf("%s valid=%v err=%v after explicit repair", name, valid, err)
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
