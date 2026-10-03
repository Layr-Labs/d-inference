package store

import (
	"context"
	"database/sql"
	"embed"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
	"github.com/pressly/goose/v3/lock"
)

// Schema changes are numbered goose migrations. SQL files live in
// schema/migrations; the Go steps are listed in goMigrations. Goose applies
// each version once and records it in migrationVersionTable. The
// schema_migrations table is a different thing: it holds the markers of the
// one-shot data migrations in the baseline.
//
//go:embed schema/migrations/*.sql
var migrationFiles embed.FS

const (
	migrationDir          = "schema/migrations"
	migrationVersionTable = "goose_db_version"

	// A DDL statement that waits for a lock blocks every later query on the
	// table. The lock timeout stops that queue after a few seconds; migrate
	// then tries again.
	migrationLockTimeout = 3 * time.Second
	// Upper bound for one statement in the migration session.
	migrationStatementTimeout = 10 * time.Minute
	migrationAttempts         = 3
)

// lockNotAvailable is the SQLSTATE of a lock_timeout failure.
const lockNotAvailable = "55P03"

// migrate applies every pending migration. Coordinators that start together
// take turns on the goose advisory lock: the first applies the pending
// versions and the others find nothing left to apply. A lock timeout is
// retried a few times, with a short pause.
func (s *PostgresStore) migrate(ctx context.Context) error {
	for attempt := 1; ; attempt++ {
		err := s.migrateOnce(ctx)
		if err == nil || attempt == migrationAttempts || !isLockTimeout(err) {
			return err
		}
		slog.Warn("postgres migration hit lock_timeout; retrying", "attempt", attempt)
		select {
		case <-ctx.Done():
			return err
		case <-time.After(time.Duration(attempt) * time.Second):
		}
	}
}

func isLockTimeout(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == lockNotAvailable
}

// migrateOnce runs goose once on a small pool of its own, so the session
// timeouts apply to the migration connections and not to the serving pool.
func (s *PostgresStore) migrateOnce(ctx context.Context) error {
	cfg := s.pool.Config()
	// One connection holds the advisory lock and runs the SQL migrations; goose
	// records Go migration versions on a second one.
	cfg.MinConns = 0
	cfg.MaxConns = 2
	// A timeout set in the database URL wins over these defaults.
	for name, value := range map[string]time.Duration{
		"lock_timeout":      migrationLockTimeout,
		"statement_timeout": migrationStatementTimeout,
	} {
		if _, set := cfg.ConnConfig.RuntimeParams[name]; !set {
			cfg.ConnConfig.RuntimeParams[name] = strconv.FormatInt(value.Milliseconds(), 10)
		}
	}
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return fmt.Errorf("store: open migration pool: %w", err)
	}
	defer pool.Close()
	db := stdlib.OpenDBFromPool(pool)
	defer db.Close()

	provider, err := s.newMigrationProvider(db)
	if err != nil {
		return err
	}
	results, err := provider.Up(ctx)
	var partial *goose.PartialError
	if errors.As(err, &partial) {
		results = append(partial.Applied, partial.Failed)
	}
	for _, r := range results {
		result := "applied"
		if r.Error != nil {
			result = "failed"
		}
		slog.Info("postgres migration", "version", r.Source.Version, "result", result,
			"duration_ms", r.Duration.Milliseconds())
	}
	if err != nil {
		return fmt.Errorf("store: apply migrations: %w", err)
	}
	return nil
}

func (s *PostgresStore) newMigrationProvider(db *sql.DB) (*goose.Provider, error) {
	fsys, err := fs.Sub(migrationFiles, migrationDir)
	if err != nil {
		return nil, fmt.Errorf("store: open embedded migrations: %w", err)
	}
	locker, err := lock.NewPostgresSessionLocker()
	if err != nil {
		return nil, fmt.Errorf("store: create migration locker: %w", err)
	}
	provider, err := goose.NewProvider(goose.DialectPostgres, db, fsys,
		goose.WithSessionLocker(locker),
		goose.WithTableName(migrationVersionTable),
		goose.WithDisableGlobalRegistry(true),
		goose.WithGoMigrations(s.allGoMigrations()...),
	)
	if err != nil {
		return nil, fmt.Errorf("store: create migration provider: %w", err)
	}
	return provider, nil
}

// goMigrations are the startup steps that ran after the old boot-time DDL
// loop, in the same order. They keep their code and run on the store pool,
// which sets no session timeouts, as before: a CREATE INDEX CONCURRENTLY that
// times out leaves an invalid index, and these steps do not repair one.
func (s *PostgresStore) goMigrations() []*goose.Migration {
	step := func(version int64, run func(context.Context) error) *goose.Migration {
		return goose.NewGoMigration(version, &goose.GoFunc{
			RunDB: func(ctx context.Context, _ *sql.DB) error { return run(ctx) },
		}, nil)
	}
	return []*goose.Migration{
		step(2, s.checkRetiredBackfills),
		step(3, s.ensureProviderRestoreIndexes),
		step(4, s.ensureProviderEarningsJobIndex),
		step(5, s.ensureProviderEarningsWindowIndex),
	}
}

// allGoMigrations are the pre-goose startup steps, then the
// CONCURRENTLY index builds.
func (s *PostgresStore) allGoMigrations() []*goose.Migration {
	return append(s.goMigrations(), s.indexMigrations()...)
}
