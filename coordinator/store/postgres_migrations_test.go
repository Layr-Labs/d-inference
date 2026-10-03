package store

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
)

// A fresh database built by goose has exactly the schema that the pre-goose
// boot loop built (schema/schema.sql).
func TestMigrationsBuildCheckedInSchema(t *testing.T) {
	ctx := context.Background()
	gooseURL := newThrowawayTestDatabase(t)
	s, err := NewPostgres(ctx, Config{DatabaseURL: gooseURL})
	if err != nil {
		t.Fatalf("NewPostgres: %v", err)
	}
	t.Cleanup(s.Close)

	dumpPool := openTestPool(t, newThrowawayTestDatabase(t))
	loadSchemaFile(t, dumpPool, checkedInSchemaFile)

	assertSameSchema(t, "schema/schema.sql", schemaSnapshot(t, dumpPool), "goose", schemaSnapshot(t, s.pool))
}

// A database that a pre-goose binary migrated meets goose for the first
// time. The baseline and the Go steps (versions 1 to 5) change nothing
// except the new goose version table; the later versions then bring it to
// the checked-in schema.
func TestMigrationsUpgradeLegacyDatabase(t *testing.T) {
	ctx := context.Background()
	databaseURL := newThrowawayTestDatabase(t)
	pool := openTestPool(t, databaseURL)
	loadSchemaFile(t, pool, preGooseSchemaFile)
	// The rows the pre-goose boot leaves on a fresh database.
	for _, stmt := range []string{
		`INSERT INTO schema_migrations (id, applied_at) VALUES
			('scrub_provider_log_report_serials_v1', '2026-01-02T03:04:05Z'),
			('scrub_inference_route_cache_affinity_v1', '2026-01-02T03:04:05Z'),
			('backfill_withdrawable_balance_v1', '2026-01-02T03:04:05Z'),
			('backfill_usage_totals_v1', '2026-01-02T03:04:05Z'),
			('backfill_earnings_summary_v1', '2026-01-02T03:04:05Z')`,
		`INSERT INTO usage_totals VALUES (1, 0, 0, 0)`,
		`INSERT INTO model_demand_collection VALUES (TRUE, '2026-01-02T03:04:05Z')`,
	} {
		if _, err := pool.Exec(ctx, stmt); err != nil {
			t.Fatalf("seed legacy rows: %v", err)
		}
	}
	const rowsSQL = `SELECT 'marker ' || id || ' ' || applied_at FROM schema_migrations
		UNION ALL SELECT 'usage_totals ' || id || ' ' || total_requests FROM usage_totals
		UNION ALL SELECT 'collection ' || started_at FROM model_demand_collection
		ORDER BY 1`
	readRows := func() []string {
		rows, err := pool.Query(ctx, rowsSQL)
		if err != nil {
			t.Fatalf("read rows: %v", err)
		}
		defer rows.Close()
		var out []string
		for rows.Next() {
			var line string
			if err := rows.Scan(&line); err != nil {
				t.Fatalf("scan row: %v", err)
			}
			out = append(out, line)
		}
		return out
	}
	schemaBefore, rowsBefore := schemaSnapshot(t, pool), readRows()

	s := &PostgresStore{pool: pool}
	db := stdlib.OpenDBFromPool(pool)
	t.Cleanup(func() { _ = db.Close() })
	provider, err := s.newMigrationProvider(db)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := provider.UpTo(ctx, lastPreGooseVersion); err != nil {
		t.Fatalf("apply versions up to %d on legacy database: %v", lastPreGooseVersion, err)
	}
	assertSameSchema(t, "legacy", schemaBefore, "after the baseline", schemaSnapshot(t, pool))
	assertSameSchema(t, "legacy rows", rowsBefore, "rows after the baseline", readRows())

	if err := s.migrate(ctx); err != nil {
		t.Fatalf("migrate legacy database: %v", err)
	}
	dumpPool := openTestPool(t, newThrowawayTestDatabase(t))
	loadSchemaFile(t, dumpPool, checkedInSchemaFile)
	assertSameSchema(t, "schema/schema.sql", schemaSnapshot(t, dumpPool), "upgraded legacy", schemaSnapshot(t, pool))
	assertSameSchema(t, "legacy rows", rowsBefore, "rows after goose", readRows())
	var versions []int64
	rows, err := pool.Query(ctx, `SELECT version_id FROM `+migrationVersionTable+` ORDER BY id`)
	if err != nil {
		t.Fatalf("read goose versions: %v", err)
	}
	defer rows.Close()
	for rows.Next() {
		var v int64
		if err := rows.Scan(&v); err != nil {
			t.Fatal(err)
		}
		versions = append(versions, v)
	}
	want := len(provider.ListSources())
	if len(versions) != want+1 || versions[0] != 0 || versions[want] != int64(want) {
		t.Fatalf("goose versions = %v, want 0 through %d", versions, want)
	}
}

// Two coordinators that start together: the goose advisory lock lets one
// apply the migrations, and the other then finds nothing to apply.
func TestConcurrentMigrationsApplyOnce(t *testing.T) {
	ctx := context.Background()
	databaseURL := newThrowawayTestDatabase(t)
	runners := make([]*goose.Provider, 2)
	for i := range runners {
		s := &PostgresStore{pool: openTestPool(t, databaseURL)}
		db := stdlib.OpenDBFromPool(s.pool)
		t.Cleanup(func() { _ = db.Close() })
		provider, err := s.newMigrationProvider(db)
		if err != nil {
			t.Fatal(err)
		}
		runners[i] = provider
	}

	var wg sync.WaitGroup
	applied := make([]int, len(runners))
	errs := make([]error, len(runners))
	for i, provider := range runners {
		wg.Add(1)
		go func() {
			defer wg.Done()
			results, err := provider.Up(ctx)
			applied[i], errs[i] = len(results), err
		}()
	}
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Fatalf("runner %d: %v", i, err)
		}
	}
	want := len(runners[0].ListSources())
	if applied[0]+applied[1] != want || (applied[0] != 0 && applied[1] != 0) {
		t.Fatalf("applied = %v, want one runner to apply all %d versions and the other none", applied, want)
	}
	var rows, distinct int
	pool := openTestPool(t, databaseURL)
	if err := pool.QueryRow(ctx, `SELECT count(*), count(DISTINCT version_id) FROM `+migrationVersionTable).Scan(&rows, &distinct); err != nil {
		t.Fatal(err)
	}
	if rows != want+1 || distinct != want+1 {
		t.Fatalf("goose version rows = %d (%d distinct), want %d", rows, distinct, want+1)
	}
}

// A DDL statement that waits longer than the lock timeout fails, and migrate
// runs goose again once the lock is free.
func TestMigrateRetriesLockTimeout(t *testing.T) {
	ctx := context.Background()
	databaseURL := newThrowawayTestDatabase(t)
	s, err := NewPostgres(ctx, Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatalf("NewPostgres: %v", err)
	}
	t.Cleanup(s.Close)
	forgetMigrationVersions(t, s)

	holder := openTestPool(t, databaseURL)
	tx, err := holder.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	// The baseline alters provider_trust_reuse outside an exception block,
	// so the lock timeout reaches migrate.
	if _, err := tx.Exec(ctx, `LOCK TABLE provider_trust_reuse IN ACCESS EXCLUSIVE MODE`); err != nil {
		t.Fatal(err)
	}
	release := time.AfterFunc(migrationLockTimeout+time.Second, func() { _ = tx.Rollback(context.Background()) })
	defer release.Stop()

	var logs bytes.Buffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&logs, nil)))
	defer slog.SetDefault(previous)
	if err := s.migrate(ctx); err != nil {
		t.Fatalf("migrate with a held lock: %v", err)
	}
	if !strings.Contains(logs.String(), "hit lock_timeout; retrying") {
		t.Fatalf("migrate did not retry after a lock timeout; logs:\n%s", logs.String())
	}
}

// A CREATE INDEX CONCURRENTLY waits for every older snapshot. A query that
// runs longer than the 3 s session lock_timeout must not cancel it: the
// CONCURRENTLY migrations wait up to a minute, and apply on the first attempt.
func TestConcurrentIndexMigrationWaitsForOlderSnapshot(t *testing.T) {
	ctx := context.Background()
	databaseURL := newThrowawayTestDatabase(t)
	s, err := NewPostgres(ctx, Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatalf("NewPostgres: %v", err)
	}
	t.Cleanup(s.Close)
	// Make version 6 pending again.
	if _, err := s.pool.Exec(ctx, `DROP INDEX idx_provider_sessions_account`); err != nil {
		t.Fatal(err)
	}
	if _, err := s.pool.Exec(ctx, `DELETE FROM `+migrationVersionTable+` WHERE version_id >= 6`); err != nil {
		t.Fatal(err)
	}

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

	var logs bytes.Buffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&logs, nil)))
	defer slog.SetDefault(previous)
	if err := s.migrate(ctx); err != nil {
		t.Fatalf("migrate behind an older snapshot: %v", err)
	}
	if strings.Contains(logs.String(), "retrying") {
		t.Fatalf("the index build hit the session lock_timeout; logs:\n%s", logs.String())
	}
	var valid bool
	if err := s.pool.QueryRow(ctx, `SELECT indisvalid FROM pg_index WHERE indexrelid = 'idx_provider_sessions_account'::regclass`).Scan(&valid); err != nil || !valid {
		t.Fatalf("idx_provider_sessions_account valid=%v err=%v", valid, err)
	}
}

// pendingFrom makes version and every later version pending again.
func pendingFrom(t *testing.T, s *PostgresStore, version int64) {
	t.Helper()
	if _, err := s.pool.Exec(context.Background(), `DELETE FROM `+migrationVersionTable+` WHERE version_id >= $1`, version); err != nil {
		t.Fatal(err)
	}
}

func versionRecorded(t *testing.T, s *PostgresStore, version int64) bool {
	t.Helper()
	var recorded bool
	if err := s.pool.QueryRow(context.Background(), `SELECT EXISTS(SELECT 1 FROM `+migrationVersionTable+` WHERE version_id = $1)`, version).Scan(&recorded); err != nil {
		t.Fatal(err)
	}
	return recorded
}

// An interrupted CONCURRENTLY build leaves an invalid index of the same name.
// The index migration drops it, builds again, and records the version only
// with a valid index.
func TestIndexMigrationRebuildsInvalidLeftover(t *testing.T) {
	ctx := context.Background()
	databaseURL := newThrowawayTestDatabase(t)
	s, err := NewPostgres(ctx, Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatalf("NewPostgres: %v", err)
	}
	t.Cleanup(s.Close)
	if _, err := s.pool.Exec(ctx, `DROP INDEX idx_provider_sessions_account`); err != nil {
		t.Fatal(err)
	}
	pendingFrom(t, s, 6)

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
	var valid bool
	if err := s.pool.QueryRow(ctx, `SELECT indisvalid FROM pg_index WHERE indexrelid = 'idx_provider_sessions_account'::regclass`).Scan(&valid); err != nil || valid {
		t.Fatalf("fixture: leftover index valid=%v err=%v, want an invalid index", valid, err)
	}

	if err := s.migrate(ctx); err != nil {
		t.Fatalf("migrate with an invalid leftover index: %v", err)
	}
	if err := s.pool.QueryRow(ctx, `SELECT indisvalid FROM pg_index WHERE indexrelid = 'idx_provider_sessions_account'::regclass`).Scan(&valid); err != nil || !valid {
		t.Fatalf("idx_provider_sessions_account valid=%v err=%v after migrate", valid, err)
	}
	if !versionRecorded(t, s, 6) {
		t.Fatal("version 6 not recorded after a successful rebuild")
	}
}

// A build that cannot produce a valid index fails the boot, and goose does
// not record the version: here the unique live-user index meets two live
// users with the same Privy ID.
func TestIndexMigrationFailureIsNotRecorded(t *testing.T) {
	ctx := context.Background()
	databaseURL := newThrowawayTestDatabase(t)
	s, err := NewPostgres(ctx, Config{DatabaseURL: databaseURL})
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
	pendingFrom(t, s, 14)

	if err := s.migrate(ctx); err == nil {
		t.Fatal("migrate succeeded although idx_users_privy_live cannot be built")
	}
	if versionRecorded(t, s, 14) {
		t.Fatal("version 14 recorded although its index build failed")
	}
}
