package postgres_test

import (
	"bytes"
	"context"
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	production "github.com/eigeninference/d-inference/coordinator/store/postgres"
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

// A fresh database built by goose has exactly the schema that the pre-goose
// boot loop built (schema/schema.sql).
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

// A database that a pre-goose binary migrated meets goose for the first
// time: every migration runs, and nothing changes except the new goose
// version table.
func TestMigrationsLeaveLegacyDatabaseUnchanged(t *testing.T) {
	ctx := context.Background()
	databaseURL := newThrowawayTestDatabase(t)
	pool := openTestPool(t, databaseURL)
	loadSchemaFile(t, pool)
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
	schemaBefore, rowsBefore := schemaSnapshot(t, pool), queryLines(t, pool, rowsSQL)

	s, err := production.NewPostgres(ctx, store.Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatalf("NewPostgres on legacy database: %v", err)
	}
	t.Cleanup(s.Close)

	assertSameLines(t, "legacy", schemaBefore, "after goose", schemaSnapshot(t, pool))
	assertSameLines(t, "legacy rows", rowsBefore, "rows after goose", queryLines(t, pool, rowsSQL))
	versions := queryLines(t, pool, `SELECT version_id::text FROM `+gooseVersionTable+` ORDER BY id`)
	if got := strings.Join(versions, " "); got != "0 1 2 3 4 5" {
		t.Fatalf("goose versions = %q, want 0 through 5", got)
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
	if want := "1:applied 2:applied 3:applied 4:applied 5:applied"; strings.Join(got, " ") != want {
		t.Fatalf("migration results = %q, want each of the 5 versions applied once; logs:\n%s", got, logs.String())
	}
	var rows, distinct int
	if err := pool.QueryRow(ctx, `SELECT count(*), count(DISTINCT version_id) FROM `+gooseVersionTable).Scan(&rows, &distinct); err != nil {
		t.Fatal(err)
	}
	if rows != 6 || distinct != 6 {
		t.Fatalf("goose version rows = %d (%d distinct), want 6", rows, distinct)
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
