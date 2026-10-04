package store

import (
	"bytes"
	"context"
	"log/slog"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

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

	s, err := NewPostgres(ctx, Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatalf("NewPostgres on legacy database: %v", err)
	}
	t.Cleanup(s.Close)

	assertSameLines(t, "legacy", schemaBefore, "after goose", schemaSnapshot(t, pool))
	assertSameLines(t, "legacy rows", rowsBefore, "rows after goose", queryLines(t, pool, rowsSQL))
	versions := queryLines(t, pool, `SELECT version_id::text FROM `+migrationVersionTable+` ORDER BY id`)
	if got := strings.Join(versions, " "); got != "0 1 2 3 4 5" {
		t.Fatalf("goose versions = %q, want 0 through 5", got)
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
	if applied[0]+applied[1] != 5 || (applied[0] != 0 && applied[1] != 0) {
		t.Fatalf("applied = %v, want one runner to apply all 5 versions and the other none", applied)
	}
	var rows, distinct int
	pool := openTestPool(t, databaseURL)
	if err := pool.QueryRow(ctx, `SELECT count(*), count(DISTINCT version_id) FROM `+migrationVersionTable).Scan(&rows, &distinct); err != nil {
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

// A CREATE INDEX CONCURRENTLY that fails leaves an invalid index, and an
// SQL file's IF NOT EXISTS would then skip it and record the version. Index
// builds therefore run as Go migrations through ensureConcurrentIndex,
// which fails unless the index ends up valid.
func TestSQLMigrationsDoNotBuildIndexesConcurrently(t *testing.T) {
	entries, err := migrationFiles.ReadDir(migrationDir)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		b, err := migrationFiles.ReadFile(migrationDir + "/" + entry.Name())
		if err != nil {
			t.Fatal(err)
		}
		if regexp.MustCompile(`(?i)CREATE\s+(UNIQUE\s+)?INDEX\s+CONCURRENTLY`).Match(b) {
			t.Errorf("%s builds an index CONCURRENTLY; use a Go migration with ensureConcurrentIndex", entry.Name())
		}
	}
}
