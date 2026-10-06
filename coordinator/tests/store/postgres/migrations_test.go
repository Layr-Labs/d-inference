package postgres_test

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	production "github.com/eigeninference/d-inference/coordinator/store/postgres"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/pressly/goose/v3/lock"
)

// migrationLockTimeout is the lock_timeout that the store sets on its
// migration sessions.
const migrationLockTimeout = 3 * time.Second

// captureLogs sends the default logger to a buffer until the test ends.
func captureLogs(t *testing.T) *bytes.Buffer {
	t.Helper()
	var logs bytes.Buffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&logs, nil)))
	t.Cleanup(func() { slog.SetDefault(previous) })
	return &logs
}

// migrationSourceCount returns the number of migration versions: the
// versions goose records on an empty database, without its version 0 row.
func migrationSourceCount(t *testing.T) int {
	t.Helper()
	ctx := context.Background()
	s, err := openPostgresFixture(ctx, store.Config{DatabaseURL: newThrowawayTestDatabase(t)})
	if err != nil {
		t.Fatalf("NewPostgres: %v", err)
	}
	defer s.Close()
	var count int
	if err := s.pool.QueryRow(ctx, `SELECT count(*) - 1 FROM `+gooseVersionTable).Scan(&count); err != nil {
		t.Fatal(err)
	}
	return count
}

// A fresh database built by goose matches the current checked-in schema.
func TestMigrationsBuildCheckedInSchema(t *testing.T) {
	ctx := context.Background()
	s, err := openPostgresFixture(ctx, store.Config{DatabaseURL: newThrowawayTestDatabase(t)})
	if err != nil {
		t.Fatalf("NewPostgres: %v", err)
	}
	t.Cleanup(s.Close)

	dumpPool := openTestPool(t, newThrowawayTestDatabase(t))
	loadSchemaFile(t, dumpPool)

	assertSameLines(t, "schema/schema.sql", schemaSnapshot(t, dumpPool), "goose", schemaSnapshot(t, s.pool))
}

// A frozen pre-goose database upgrades to the current schema without
// changing the existing migration markers, counters or collection epoch.
func TestMigrationsUpgradeLegacyDatabase(t *testing.T) {
	for _, gooseBaseline := range []bool{false, true} {
		name := "pre_goose"
		if gooseBaseline {
			name = "goose_version_5"
		}
		t.Run(name, func(t *testing.T) { testMigrationsUpgradeLegacyDatabase(t, gooseBaseline) })
	}
}

func testMigrationsUpgradeLegacyDatabase(t *testing.T, gooseBaseline bool) {
	ctx := context.Background()
	databaseURL := newThrowawayTestDatabase(t)
	pool := openTestPool(t, databaseURL)
	loadSchema(t, pool, legacySchemaFile)
	if gooseBaseline {
		// Public Goose version-table shape, as left by the original five-version
		// build. The frozen schema already contains those versions' objects.
		if _, err := pool.Exec(ctx, `CREATE TABLE goose_db_version (
			id serial PRIMARY KEY, version_id bigint NOT NULL,
			is_applied boolean NOT NULL, tstamp timestamp NOT NULL DEFAULT now());
			INSERT INTO goose_db_version (version_id, is_applied, tstamp)
			SELECT n, true, '2026-01-02T03:04:05Z' FROM generate_series(0, 5) n`); err != nil {
			t.Fatal(err)
		}
	}
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
	rowsBefore := queryLines(t, pool, rowsSQL)

	s, err := production.NewPostgres(ctx, store.Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatalf("NewPostgres on legacy database: %v", err)
	}
	t.Cleanup(s.Close)

	current := openTestPool(t, newThrowawayTestDatabase(t))
	loadSchemaFile(t, current)
	assertSameLines(t, "current schema", schemaSnapshot(t, current), "upgraded legacy", schemaSnapshot(t, pool))
	assertSameLines(t, "legacy rows", rowsBefore, "rows after goose", queryLines(t, pool, rowsSQL))
	if gooseBaseline {
		rows := queryLines(t, pool, `SELECT version_id::text FROM goose_db_version
			WHERE version_id <= 5 AND tstamp = '2026-01-02T03:04:05Z' ORDER BY id`)
		if strings.Join(rows, " ") != "0 1 2 3 4 5" {
			t.Fatalf("original version history changed: %v", rows)
		}
	}
	versions := queryLines(t, pool, `SELECT version_id::text FROM `+gooseVersionTable+` ORDER BY id`)
	want := migrationSourceCount(t)
	var expected []string
	for version := 0; version <= want; version++ {
		expected = append(expected, strconv.Itoa(version))
	}
	if got := strings.Join(versions, " "); got != strings.Join(expected, " ") {
		t.Fatalf("goose versions = %q, want 0 through %d", got, want)
	}
}

// Two coordinators that start together: the goose advisory lock lets the
// versions apply once, and the other coordinator finds nothing left to apply.
// The test holds the lock while both start, so neither may touch the schema
// until it is released; then both race for it.
func TestConcurrentMigrationsApplyOnce(t *testing.T) {
	ctx := context.Background()
	databaseURL := newThrowawayTestDatabase(t)
	pool := openTestPool(t, databaseURL)
	holder, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer holder.Release()
	if _, err := holder.Exec(ctx, "SELECT pg_advisory_lock($1)", lock.DefaultLockID); err != nil {
		t.Fatalf("take goose lock: %v", err)
	}
	logs := captureLogs(t)

	var wg sync.WaitGroup
	errs := make([]error, 2)
	for i := range errs {
		wg.Add(1)
		go func() {
			defer wg.Done()
			s, err := production.NewPostgres(ctx, store.Config{DatabaseURL: databaseURL})
			if err == nil {
				s.Close()
			}
			errs[i] = err
		}()
	}

	// The baseline creates this table with its first statement.
	time.Sleep(2 * time.Second)
	var firstTable *string
	if err := pool.QueryRow(ctx, `SELECT to_regclass('global_payout_recipients')::text`).Scan(&firstTable); err != nil {
		t.Fatal(err)
	}
	if firstTable != nil {
		t.Fatalf("a coordinator migrated while another session held the goose advisory lock; logs:\n%s", logs.String())
	}
	if _, err := holder.Exec(ctx, "SELECT pg_advisory_unlock($1)", lock.DefaultLockID); err != nil {
		t.Fatalf("release goose lock: %v", err)
	}
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Fatalf("coordinator %d: %v", i, err)
		}
	}

	applied := regexp.MustCompile(`msg="postgres migration" version=(\d+) result=(\w+)`).FindAllStringSubmatch(logs.String(), -1)
	var got []string
	for _, m := range applied {
		got = append(got, m[1]+":"+m[2])
	}
	want := migrationSourceCount(t)
	var expected []string
	for version := 1; version <= want; version++ {
		expected = append(expected, strconv.Itoa(version)+":applied")
	}
	if strings.Join(got, " ") != strings.Join(expected, " ") {
		t.Fatalf("migration results = %q, want each of the %d versions applied once; logs:\n%s", got, want, logs.String())
	}
	var rows, distinct int
	if err := pool.QueryRow(ctx, `SELECT count(*), count(DISTINCT version_id) FROM `+gooseVersionTable).Scan(&rows, &distinct); err != nil {
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
	s, err := openPostgresFixture(ctx, store.Config{DatabaseURL: databaseURL})
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

	logs := captureLogs(t)
	if err := s.reopen(ctx); err != nil {
		t.Fatalf("migrate with a held lock: %v", err)
	}
	if !strings.Contains(logs.String(), "hit lock_timeout; retrying") {
		t.Fatalf("migrate did not retry after a lock timeout; logs:\n%s", logs.String())
	}
}

// A CREATE INDEX CONCURRENTLY that fails leaves an invalid index, and an
// SQL file's IF NOT EXISTS would then skip it and record the version. Index
// builds therefore run as Go migrations through ensureConcurrentIndex,
// which fails unless the index ends up valid.
func TestSQLMigrationsDoNotBuildIndexesConcurrently(t *testing.T) {
	files, err := filepath.Glob(filepath.Join(migrationSQLDir, "*.sql"))
	if err != nil {
		t.Fatal(err)
	}
	if len(files) == 0 {
		t.Fatalf("no SQL migrations in %s", migrationSQLDir)
	}
	for _, file := range files {
		b, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		if regexp.MustCompile(`(?i)CREATE\s+(UNIQUE\s+)?INDEX\s+CONCURRENTLY`).Match(b) {
			t.Errorf("%s builds an index CONCURRENTLY; use a Go migration with ensureConcurrentIndex", filepath.Base(file))
		}
	}
}

// A pre-goose database may be missing a column from an earlier failed boot.
// A lock timeout must leave the entire baseline pending, so the next startup
// retries the missing column instead of trusting an incomplete version marker.
func TestMigrationsBlockedLegacyColumnRemainsPending(t *testing.T) {
	ctx := context.Background()
	databaseURL := newThrowawayTestDatabase(t)
	pool := openTestPool(t, databaseURL)
	loadSchema(t, pool, legacySchemaFile)
	if _, err := pool.Exec(ctx, `ALTER TABLE providers DROP COLUMN version`); err != nil {
		t.Fatal(err)
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `LOCK TABLE providers IN ACCESS SHARE MODE`); err != nil {
		t.Fatal(err)
	}

	blockedURL := databaseURL + "&lock_timeout=100ms"
	blocked, err := production.NewPostgres(ctx, store.Config{DatabaseURL: blockedURL})
	if blocked != nil {
		blocked.Close()
	}
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Code != "55P03" {
		t.Fatalf("blocked missing-column migration = %v, want lock timeout", err)
	}
	var applied bool
	if err := pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM goose_db_version WHERE version_id = 1 AND is_applied)`).Scan(&applied); err != nil {
		t.Fatal(err)
	}
	if applied {
		t.Fatal("blocked baseline was recorded as applied")
	}
	if err := tx.Rollback(ctx); err != nil {
		t.Fatal(err)
	}

	migrated, err := production.NewPostgres(ctx, store.Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatalf("retry after releasing lock: %v", err)
	}
	t.Cleanup(migrated.Close)
	var columnPresent bool
	if err := pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = 'providers' AND column_name = 'version')`).Scan(&columnPresent); err != nil {
		t.Fatal(err)
	}
	if !columnPresent {
		t.Fatal("retry did not restore providers.version")
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
