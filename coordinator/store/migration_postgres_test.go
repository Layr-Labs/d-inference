package store

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

var migrationSchemaSequence atomic.Uint64

func TestPostgresMigrationsFreshDatabase(t *testing.T) {
	databaseURL := migrationTestDatabase(t)
	ctx := context.Background()

	result, err := ApplyPostgresMigrations(ctx, databaseURL, MigrationOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if fmt.Sprint(result.Applied) != "[1 2 3]" {
		t.Fatalf("applied = %v, want [1 2 3]", result.Applied)
	}
	if result.DatabaseVersion != MaximumSupportedSchemaVersion {
		t.Fatalf("database version = %d", result.DatabaseVersion)
	}

	backend, err := NewPostgres(ctx, Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatalf("NewPostgres after migration: %v", err)
	}
	backend.Close()

	conn := migrationTestConn(t, databaseURL)
	defer conn.Close(ctx)
	var (
		versionCount int
		indexValid   bool
	)
	if err := conn.QueryRow(ctx, `SELECT count(*) FROM schema_migration_versions`).Scan(&versionCount); err != nil {
		t.Fatal(err)
	}
	if versionCount != int(MaximumSupportedSchemaVersion) {
		t.Fatalf("metadata rows = %d", versionCount)
	}
	if err := conn.QueryRow(ctx, `
		SELECT COALESCE((
			SELECT i.indisvalid
			FROM pg_class c
			JOIN pg_index i ON i.indexrelid = c.oid
			WHERE c.oid = to_regclass('idx_provider_earnings_job')
		), false)`).Scan(&indexValid); err != nil {
		t.Fatal(err)
	}
	if !indexValid {
		t.Fatal("concurrent provider earnings index is missing or invalid")
	}
	var (
		rustSchemaVersion int64
		minimumPublic     int64
		maximumPublic     int64
		jobsTableExists   bool
	)
	if err := conn.QueryRow(ctx, `
		SELECT version, minimum_public_schema_version, maximum_public_schema_version
		FROM rust_coord.schema_versions
		ORDER BY version DESC
		LIMIT 1`).Scan(&rustSchemaVersion, &minimumPublic, &maximumPublic); err != nil {
		t.Fatal(err)
	}
	if rustSchemaVersion != 1 || minimumPublic != 3 || maximumPublic != 3 {
		t.Fatalf(
			"Rust schema compatibility = version %d public [%d,%d], want version 1 public [3,3]",
			rustSchemaVersion,
			minimumPublic,
			maximumPublic,
		)
	}
	if err := conn.QueryRow(ctx,
		`SELECT to_regclass('rust_coord.inference_jobs') IS NOT NULL`,
	).Scan(&jobsTableExists); err != nil {
		t.Fatal(err)
	}
	if jobsTableExists {
		t.Fatal("Rust compatibility migration created inference jobs prematurely")
	}

	result, err = ApplyPostgresMigrations(ctx, databaseURL, MigrationOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Applied) != 0 {
		t.Fatalf("re-entrant apply ran versions %v", result.Applied)
	}
}

func TestPostgresMigrationsSuccessfullyAdoptLegacyDatabaseExplicitly(t *testing.T) {
	databaseURL := migrationTestDatabase(t)
	ctx := context.Background()
	conn := prepareUnversionedLegacySchema(t, databaseURL)
	defer conn.Close(ctx)

	if _, err := conn.Exec(ctx, `
		CREATE UNIQUE INDEX idx_provider_earnings_job
		ON provider_earnings(job_id) WHERE job_id <> ''`); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(ctx, `
		INSERT INTO balances (account_id, balance_micro_usd, withdrawable_micro_usd)
		VALUES ('legacy-account', 1234, 321)`); err != nil {
		t.Fatal(err)
	}

	if backend, err := NewPostgres(ctx, Config{DatabaseURL: databaseURL}); err == nil {
		backend.Close()
		t.Fatal("NewPostgres accepted an unversioned legacy database")
	} else if !strings.Contains(err.Error(), "unversioned") ||
		!strings.Contains(err.Error(), "coordinator-migrate") {
		t.Fatalf("unversioned error = %v", err)
	}

	result, err := ApplyPostgresMigrations(ctx, databaseURL, MigrationOptions{})
	if err == nil || !strings.Contains(err.Error(), "-adopt-legacy") {
		t.Fatalf("missing explicit adoption error = %v", err)
	}
	var metadataExists bool
	if err := conn.QueryRow(ctx,
		`SELECT to_regclass('schema_migration_versions') IS NOT NULL`,
	).Scan(&metadataExists); err != nil {
		t.Fatal(err)
	}
	if metadataExists {
		t.Fatal("legacy database was modified before explicit adoption")
	}

	result, err = ApplyPostgresMigrations(ctx, databaseURL, MigrationOptions{AdoptLegacy: true})
	if err != nil {
		t.Fatal(err)
	}
	if fmt.Sprint(result.Applied) != "[1 2 3]" {
		t.Fatalf("legacy adoption applied = %v, want [1 2 3]", result.Applied)
	}
	var balance, withdrawable int64
	if err := conn.QueryRow(ctx, `
		SELECT balance_micro_usd, withdrawable_micro_usd
		FROM balances WHERE account_id = 'legacy-account'`).Scan(&balance, &withdrawable); err != nil {
		t.Fatal(err)
	}
	if balance != 1234 || withdrawable != 321 {
		t.Fatalf("legacy balance changed to %d/%d", balance, withdrawable)
	}
}

func TestPostgresMigrationsRejectUnrelatedDatabase(t *testing.T) {
	databaseURL := migrationTestDatabase(t)
	ctx := context.Background()
	conn := migrationTestConn(t, databaseURL)
	defer conn.Close(ctx)
	if _, err := conn.Exec(ctx, `CREATE TABLE customer_accounts (id BIGINT PRIMARY KEY)`); err != nil {
		t.Fatal(err)
	}

	for _, options := range []MigrationOptions{{}, {AdoptLegacy: true}} {
		if _, err := ApplyPostgresMigrations(ctx, databaseURL, options); err == nil {
			t.Fatal("migration accepted an unrelated nonempty database")
		} else if !strings.Contains(err.Error(), "legacy fingerprint mismatch") {
			t.Fatalf("unrelated database error = %v", err)
		}
	}
	var metadataExists bool
	if err := conn.QueryRow(ctx,
		`SELECT to_regclass('schema_migration_versions') IS NOT NULL`,
	).Scan(&metadataExists); err != nil {
		t.Fatal(err)
	}
	if metadataExists {
		t.Fatal("unrelated database was modified")
	}
}

func TestPostgresMigrationsRejectUnrelatedDatabaseWithBootstrapMarker(t *testing.T) {
	databaseURL := migrationTestDatabase(t)
	ctx := context.Background()
	conn := migrationTestConn(t, databaseURL)
	defer conn.Close(ctx)
	if _, err := conn.Exec(ctx, `
		CREATE TABLE schema_migration_versions (
			version BIGINT PRIMARY KEY CHECK (version > 0),
			name TEXT NOT NULL,
			checksum TEXT NOT NULL CHECK (length(checksum) = 64),
			transactional BOOLEAN NOT NULL,
			applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);
		CREATE TABLE customer_accounts (id BIGINT PRIMARY KEY)`); err != nil {
		t.Fatal(err)
	}

	if _, err := ApplyPostgresMigrations(
		ctx,
		databaseURL,
		MigrationOptions{AdoptLegacy: true},
	); err == nil {
		t.Fatal("migration accepted an unrelated database with an empty metadata table")
	} else if !strings.Contains(err.Error(), `unexpected relation "customer_accounts"`) {
		t.Fatalf("unrelated bootstrap-marker error = %v", err)
	}
	assertMigrationVersionCount(t, conn, 1, 0)
}

func TestPostgresMigrationsRejectIncompatibleLegacyColumnType(t *testing.T) {
	databaseURL := migrationTestDatabase(t)
	ctx := context.Background()
	conn := prepareUnversionedLegacySchema(t, databaseURL)
	defer conn.Close(ctx)
	if _, err := conn.Exec(ctx, `
		ALTER TABLE provider_earnings
		ALTER COLUMN job_id TYPE INTEGER USING 0`); err != nil {
		t.Fatal(err)
	}

	if _, err := ApplyPostgresMigrations(
		ctx,
		databaseURL,
		MigrationOptions{AdoptLegacy: true},
	); err == nil {
		t.Fatal("migration adopted a legacy database with an incompatible key type")
	} else if !strings.Contains(err.Error(), "provider_earnings.job_id has type integer, want text") {
		t.Fatalf("incompatible legacy error = %v", err)
	}
	var metadataExists bool
	if err := conn.QueryRow(ctx,
		`SELECT to_regclass('schema_migration_versions') IS NOT NULL`,
	).Scan(&metadataExists); err != nil {
		t.Fatal(err)
	}
	if metadataExists {
		t.Fatal("incompatible legacy database was modified")
	}
}

func TestPostgresMigrationRecoversInvalidConcurrentIndex(t *testing.T) {
	databaseURL := migrationTestDatabase(t)
	ctx := context.Background()
	if _, err := ApplyPostgresMigrations(ctx, databaseURL, MigrationOptions{}); err != nil {
		t.Fatal(err)
	}
	conn := migrationTestConn(t, databaseURL)
	defer conn.Close(ctx)

	if _, err := conn.Exec(ctx, `
		DELETE FROM schema_migration_versions WHERE version >= 2;
		DROP INDEX idx_provider_earnings_job;
		INSERT INTO provider_earnings
		    (account_id, provider_id, provider_key, job_id, model, amount_micro_usd)
		VALUES
		    ('a', 'p1', 'k1', 'duplicate-job', 'm', 1),
		    ('a', 'p2', 'k2', 'duplicate-job', 'm', 1)`); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(ctx, `
		CREATE UNIQUE INDEX CONCURRENTLY idx_provider_earnings_job
		ON provider_earnings(job_id) WHERE job_id <> ''`); err == nil {
		t.Fatal("duplicate rows unexpectedly produced a valid unique index")
	}
	if valid, err := concurrentIndexDefinitionMatches(ctx, conn, "idx_provider_earnings_job"); err != nil {
		t.Fatal(err)
	} else if valid {
		t.Fatal("failed concurrent build was unexpectedly valid")
	}

	if _, err := ApplyPostgresMigrations(ctx, databaseURL, MigrationOptions{}); err == nil {
		t.Fatal("migration accepted duplicate provider earnings")
	} else if !strings.Contains(err.Error(), "duplicate provider_earnings.job_id") {
		t.Fatalf("duplicate error = %v", err)
	}
	var versionTwoRows int
	if err := conn.QueryRow(ctx, `
		SELECT count(*) FROM schema_migration_versions WHERE version = 2`).Scan(&versionTwoRows); err != nil {
		t.Fatal(err)
	}
	if versionTwoRows != 0 {
		t.Fatal("failed nontransactional migration was marked applied")
	}

	if _, err := conn.Exec(ctx, `
		DELETE FROM provider_earnings
		WHERE id = (
			SELECT max(id) FROM provider_earnings WHERE job_id = 'duplicate-job'
		)`); err != nil {
		t.Fatal(err)
	}
	result, err := ApplyPostgresMigrations(ctx, databaseURL, MigrationOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if fmt.Sprint(result.Applied) != "[2 3]" {
		t.Fatalf("recovery applied = %v, want [2 3]", result.Applied)
	}
	if valid, err := concurrentIndexDefinitionMatches(ctx, conn, "idx_provider_earnings_job"); err != nil {
		t.Fatal(err)
	} else if !valid {
		t.Fatal("recovered concurrent index is not valid")
	}
}

func TestPostgresMigrationRepairsValidWrongConcurrentIndex(t *testing.T) {
	tests := []struct {
		name string
		sql  string
	}{
		{
			name: "nonunique",
			sql: `CREATE INDEX idx_provider_earnings_job
			      ON provider_earnings(job_id) WHERE job_id <> ''`,
		},
		{
			name: "wrong key",
			sql: `CREATE UNIQUE INDEX idx_provider_earnings_job
			      ON provider_earnings(provider_id) WHERE provider_id <> ''`,
		},
		{
			name: "wrong predicate",
			sql: `CREATE UNIQUE INDEX idx_provider_earnings_job
			      ON provider_earnings(job_id) WHERE job_id IS NOT NULL`,
		},
		{
			name: "wrong table",
			sql: `CREATE UNIQUE INDEX idx_provider_earnings_job
			      ON provider_sessions(session_id) WHERE session_id <> ''`,
		},
		{
			name: "wrong opclass",
			sql: `CREATE UNIQUE INDEX idx_provider_earnings_job
			      ON provider_earnings(job_id text_pattern_ops) WHERE job_id <> ''`,
		},
		{
			name: "wrong collation",
			sql: `CREATE UNIQUE INDEX idx_provider_earnings_job
			      ON provider_earnings(job_id COLLATE "C") WHERE job_id <> ''`,
		},
		{
			name: "wrong sort options",
			sql: `CREATE UNIQUE INDEX idx_provider_earnings_job
			      ON provider_earnings(job_id DESC) WHERE job_id <> ''`,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			databaseURL := migrationTestDatabase(t)
			ctx := context.Background()
			if _, err := ApplyPostgresMigrations(ctx, databaseURL, MigrationOptions{}); err != nil {
				t.Fatal(err)
			}
			conn := migrationTestConn(t, databaseURL)
			defer conn.Close(ctx)
			if _, err := conn.Exec(ctx, `
				DELETE FROM schema_migration_versions WHERE version >= 2;
				DROP INDEX idx_provider_earnings_job`); err != nil {
				t.Fatal(err)
			}
			if _, err := conn.Exec(ctx, test.sql); err != nil {
				t.Fatal(err)
			}
			if matches, err := concurrentIndexDefinitionMatches(
				ctx,
				conn,
				"idx_provider_earnings_job",
			); err != nil {
				t.Fatal(err)
			} else if matches {
				t.Fatal("valid but wrong index matched the canonical definition")
			}

			result, err := ApplyPostgresMigrations(ctx, databaseURL, MigrationOptions{})
			if err != nil {
				t.Fatal(err)
			}
			if fmt.Sprint(result.Applied) != "[2 3]" {
				t.Fatalf("repair applied = %v, want [2 3]", result.Applied)
			}
			if matches, err := concurrentIndexDefinitionMatches(
				ctx,
				conn,
				"idx_provider_earnings_job",
			); err != nil {
				t.Fatal(err)
			} else if !matches {
				t.Fatal("migration did not install the canonical index definition")
			}
		})
	}
}

func TestPostgresTransactionalMigrationRollsBackOnFailure(t *testing.T) {
	databaseURL := migrationTestDatabase(t)
	ctx := context.Background()
	if _, err := ApplyPostgresMigrations(ctx, databaseURL, MigrationOptions{}); err != nil {
		t.Fatal(err)
	}
	conn := migrationTestConn(t, databaseURL)
	defer conn.Close(ctx)

	m := migration{
		Version:       90,
		Name:          "transaction_rollback_probe",
		Checksum:      strings.Repeat("a", 64),
		SQL:           `CREATE TABLE migration_tx_rollback_probe (id INTEGER PRIMARY KEY); SELECT 1 / 0`,
		Transactional: true,
	}
	if err := applyMigration(ctx, conn, m, true); err == nil {
		t.Fatal("transactional migration unexpectedly succeeded")
	}
	var tableExists bool
	if err := conn.QueryRow(ctx,
		`SELECT to_regclass('migration_tx_rollback_probe') IS NOT NULL`,
	).Scan(&tableExists); err != nil {
		t.Fatal(err)
	}
	if tableExists {
		t.Fatal("transactional migration left DDL behind after rollback")
	}
	assertMigrationVersionCount(t, conn, m.Version, 0)
}

func TestPostgresAutocommitMigrationRetriesPartialFailure(t *testing.T) {
	databaseURL := migrationTestDatabase(t)
	ctx := context.Background()
	conn := prepareUnversionedLegacySchema(t, databaseURL)
	defer conn.Close(ctx)

	m := migration{
		Version:  1,
		Name:     "autocommit_bootstrap_retry_probe",
		Checksum: strings.Repeat("b", 64),
		SQL: `
			CREATE TABLE IF NOT EXISTS schema_migration_versions (
				version BIGINT PRIMARY KEY CHECK (version > 0),
				name TEXT NOT NULL,
				checksum TEXT NOT NULL CHECK (length(checksum) = 64),
				transactional BOOLEAN NOT NULL,
				applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
			);
			CREATE TABLE IF NOT EXISTS migration_autocommit_retry_probe (
				id INTEGER PRIMARY KEY
			);
			INSERT INTO migration_autocommit_retry_probe (id)
			VALUES (1) ON CONFLICT (id) DO NOTHING;
			DO $$
			BEGIN
				IF to_regclass('migration_autocommit_retry_gate') IS NULL THEN
					RAISE EXCEPTION 'retry gate is closed';
				END IF;
			END $$;`,
		Transactional: false,
		Bootstrap:     true,
	}
	if err := applyMigration(ctx, conn, m, false); err == nil {
		t.Fatal("autocommit migration unexpectedly succeeded before retry gate")
	}
	var rows int
	if err := conn.QueryRow(ctx,
		`SELECT count(*) FROM migration_autocommit_retry_probe`,
	).Scan(&rows); err != nil {
		t.Fatalf("first autocommit statement did not persist: %v", err)
	}
	if rows != 1 {
		t.Fatalf("rows after partial failure = %d, want 1", rows)
	}
	assertMigrationVersionCount(t, conn, m.Version, 0)

	if _, err := conn.Exec(ctx, `CREATE TABLE migration_autocommit_retry_gate (id INTEGER)`); err != nil {
		t.Fatal(err)
	}
	if err := applyMigration(ctx, conn, m, true); err != nil {
		t.Fatalf("retry failed: %v", err)
	}
	if err := conn.QueryRow(ctx,
		`SELECT count(*) FROM migration_autocommit_retry_probe`,
	).Scan(&rows); err != nil {
		t.Fatal(err)
	}
	if rows != 1 {
		t.Fatalf("retry duplicated persisted work: rows = %d", rows)
	}
	assertMigrationVersionCount(t, conn, m.Version, 1)
}

func assertMigrationVersionCount(t *testing.T, conn *pgx.Conn, version int64, want int) {
	t.Helper()
	var count int
	if err := conn.QueryRow(context.Background(),
		`SELECT count(*) FROM schema_migration_versions WHERE version = $1`,
		version,
	).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != want {
		t.Fatalf("metadata rows for version %d = %d, want %d", version, count, want)
	}
}

func TestPostgresCriticalShapeValidatedBeforeRecordingMigration(t *testing.T) {
	databaseURL := migrationTestDatabase(t)
	ctx := context.Background()
	if _, err := ApplyPostgresMigrations(ctx, databaseURL, MigrationOptions{}); err != nil {
		t.Fatal(err)
	}
	conn := migrationTestConn(t, databaseURL)
	defer conn.Close(ctx)
	if _, err := conn.Exec(ctx, `
		DELETE FROM schema_migration_versions WHERE version >= 2;
		ALTER TABLE usage ALTER COLUMN request_id DROP NOT NULL`); err != nil {
		t.Fatal(err)
	}

	if _, err := ApplyPostgresMigrations(ctx, databaseURL, MigrationOptions{}); err == nil {
		t.Fatal("migration recorded despite an incompatible critical column")
	} else if !strings.Contains(err.Error(), "usage.request_id must be NOT NULL") {
		t.Fatalf("critical shape error = %v", err)
	}
	assertMigrationVersionCount(t, conn, 2, 0)
}

func TestPostgresCriticalShapeValidatedBeforeServing(t *testing.T) {
	databaseURL := migrationTestDatabase(t)
	ctx := context.Background()
	if _, err := ApplyPostgresMigrations(ctx, databaseURL, MigrationOptions{}); err != nil {
		t.Fatal(err)
	}
	conn := migrationTestConn(t, databaseURL)
	if _, err := conn.Exec(ctx,
		`ALTER TABLE usage ALTER COLUMN request_id DROP NOT NULL`,
	); err != nil {
		conn.Close(ctx)
		t.Fatal(err)
	}
	conn.Close(ctx)

	if backend, err := NewPostgres(ctx, Config{DatabaseURL: databaseURL}); err == nil {
		backend.Close()
		t.Fatal("NewPostgres served against an incompatible critical schema")
	} else if !strings.Contains(err.Error(), "usage.request_id must be NOT NULL") {
		t.Fatalf("serving critical shape error = %v", err)
	}
}

func TestPostgresSchemaChecksumAndVersionCompatibility(t *testing.T) {
	databaseURL := migrationTestDatabase(t)
	ctx := context.Background()
	if _, err := ApplyPostgresMigrations(ctx, databaseURL, MigrationOptions{}); err != nil {
		t.Fatal(err)
	}
	conn := migrationTestConn(t, databaseURL)
	defer conn.Close(ctx)

	if _, err := conn.Exec(ctx, `
		UPDATE schema_migration_versions
		SET checksum = repeat('0', 64)
		WHERE version = 1`); err != nil {
		t.Fatal(err)
	}
	if backend, err := NewPostgres(ctx, Config{DatabaseURL: databaseURL}); err == nil {
		backend.Close()
		t.Fatal("NewPostgres accepted a changed migration checksum")
	} else if !strings.Contains(err.Error(), "checksum mismatch") {
		t.Fatalf("checksum error = %v", err)
	}

	catalog, err := loadMigrations()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(ctx,
		`UPDATE schema_migration_versions SET checksum = $1 WHERE version = 1`,
		catalog[0].Checksum,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(ctx, `
		INSERT INTO schema_migration_versions (version, name, checksum, transactional)
		VALUES ($1, 'future', repeat('f', 64), true)`,
		MaximumSupportedSchemaVersion+1,
	); err != nil {
		t.Fatal(err)
	}
	if backend, err := NewPostgres(ctx, Config{DatabaseURL: databaseURL}); err == nil {
		backend.Close()
		t.Fatal("NewPostgres accepted a future schema")
	} else if !strings.Contains(err.Error(), "outside this binary's supported range") {
		t.Fatalf("future schema error = %v", err)
	}
}

func TestPostgresMigrationLockAndStatementTimeoutsAreBounded(t *testing.T) {
	databaseURL := migrationTestDatabase(t)
	ctx := context.Background()
	if _, err := ApplyPostgresMigrations(ctx, databaseURL, MigrationOptions{}); err != nil {
		t.Fatal(err)
	}
	lockHolder := migrationTestConn(t, databaseURL)
	defer lockHolder.Close(ctx)

	var locked bool
	if err := lockHolder.QueryRow(ctx,
		`SELECT pg_try_advisory_lock(hashtextextended($1, 0))`,
		migrationAdvisoryLockKey,
	).Scan(&locked); err != nil {
		t.Fatal(err)
	}
	if !locked {
		t.Fatal("could not hold migration advisory lock")
	}

	started := time.Now()
	_, err := ApplyPostgresMigrations(ctx, databaseURL, MigrationOptions{
		LockTimeout:      75 * time.Millisecond,
		StatementTimeout: time.Second,
	})
	if err == nil || !strings.Contains(err.Error(), "advisory lock timeout") {
		t.Fatalf("lock timeout error = %v", err)
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("bounded lock wait took %s", elapsed)
	}

	timeoutConn := migrationTestConn(t, databaseURL)
	defer timeoutConn.Close(ctx)
	if err := configureMigrationTimeouts(ctx, timeoutConn, MigrationOptions{
		LockTimeout:      37 * time.Millisecond,
		StatementTimeout: 123 * time.Millisecond,
	}); err != nil {
		t.Fatal(err)
	}
	var lockTimeout, statementTimeout string
	if err := timeoutConn.QueryRow(ctx, `
		SELECT current_setting('lock_timeout'), current_setting('statement_timeout')`,
	).Scan(&lockTimeout, &statementTimeout); err != nil {
		t.Fatal(err)
	}
	if lockTimeout != "37ms" || statementTimeout != "123ms" {
		t.Fatalf("timeouts = %s/%s, want 37ms/123ms", lockTimeout, statementTimeout)
	}
}

func prepareUnversionedLegacySchema(t *testing.T, databaseURL string) *pgx.Conn {
	t.Helper()
	ctx := context.Background()
	conn := migrationTestConn(t, databaseURL)
	catalog, err := loadMigrations()
	if err != nil {
		conn.Close(ctx)
		t.Fatal(err)
	}
	statements, err := splitSQLStatements(catalog[0].SQL)
	if err != nil {
		conn.Close(ctx)
		t.Fatal(err)
	}
	if err := executeMigrationStatements(ctx, conn, catalog[0], statements); err != nil {
		conn.Close(ctx)
		t.Fatal(err)
	}
	if _, err := conn.Exec(ctx, `DROP TABLE schema_migration_versions`); err != nil {
		conn.Close(ctx)
		t.Fatal(err)
	}
	return conn
}

func TestMigrationRejectsPreexistingRustNamespace(t *testing.T) {
	databaseURL := migrationTestDatabase(t)
	ctx := context.Background()
	adminURL := os.Getenv("DATABASE_URL")
	admin := migrationTestConn(t, adminURL)
	if _, err := admin.Exec(ctx, `
		DROP SCHEMA IF EXISTS rust_coord CASCADE;
		CREATE SCHEMA rust_coord;
		CREATE TABLE rust_coord.unrelated (id BIGINT PRIMARY KEY)`); err != nil {
		admin.Close(ctx)
		t.Fatal(err)
	}
	admin.Close(ctx)
	t.Cleanup(func() {
		cleanup := migrationTestConn(t, adminURL)
		_, _ = cleanup.Exec(context.Background(), `DROP SCHEMA IF EXISTS rust_coord CASCADE`)
		cleanup.Close(context.Background())
		if _, err := ApplyPostgresMigrations(
			context.Background(), databaseURL, MigrationOptions{},
		); err != nil {
			t.Errorf("restore Rust compatibility schema: %v", err)
		}
	})

	_, err := ApplyPostgresMigrations(ctx, databaseURL, MigrationOptions{})
	if err == nil || !strings.Contains(err.Error(), "refusing to adopt pre-existing rust_coord namespace") {
		t.Fatalf("namespace collision error = %v", err)
	}
}

func migrationTestDatabase(t *testing.T) string {
	t.Helper()
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		t.Skip("DATABASE_URL not set — skipping PostgreSQL migration test")
	}
	schema := fmt.Sprintf(
		"migration_test_%d_%d",
		time.Now().UnixNano(),
		migrationSchemaSequence.Add(1),
	)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	admin := migrationTestConn(t, databaseURL)
	if _, err := admin.Exec(ctx, "CREATE SCHEMA "+pgx.Identifier{schema}.Sanitize()); err != nil {
		admin.Close(ctx)
		t.Fatalf("create migration test schema: %v", err)
	}
	admin.Close(ctx)

	isolatedURL, err := databaseURLWithSearchPath(databaseURL, schema)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cleanupCancel()
		conn, err := pgx.Connect(cleanupCtx, databaseURL)
		if err != nil {
			t.Errorf("connect to drop migration test schema: %v", err)
			return
		}
		defer conn.Close(cleanupCtx)
		if _, err := conn.Exec(
			cleanupCtx,
			"DROP SCHEMA "+pgx.Identifier{schema}.Sanitize()+" CASCADE",
		); err != nil {
			t.Errorf("drop migration test schema: %v", err)
		}
	})
	return isolatedURL
}

func migrationTestConn(t *testing.T, databaseURL string) *pgx.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	conn, err := pgx.Connect(ctx, databaseURL)
	if err != nil {
		t.Fatalf("connect migration test database: %v", err)
	}
	return conn
}

func databaseURLWithSearchPath(databaseURL, schema string) (string, error) {
	parsed, err := url.Parse(databaseURL)
	if err == nil && (parsed.Scheme == "postgres" || parsed.Scheme == "postgresql") {
		query := parsed.Query()
		query.Set("search_path", schema)
		parsed.RawQuery = query.Encode()
		return parsed.String(), nil
	}
	if strings.TrimSpace(databaseURL) == "" {
		return "", fmt.Errorf("empty database URL")
	}
	return databaseURL + " search_path=" + schema, nil
}
