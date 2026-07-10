package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

const migrationAdvisoryLockKey = "darkbloom-schema-migrations"

const (
	DefaultMigrationLockTimeout      = 10 * time.Second
	DefaultMigrationStatementTimeout = 30 * time.Minute
)

type MigrationOptions struct {
	LockTimeout      time.Duration
	StatementTimeout time.Duration
	AdoptLegacy      bool
}

type MigrationResult struct {
	DatabaseVersion int64
	Applied         []int64
}

type appliedMigration struct {
	Version       int64
	Name          string
	Checksum      string
	Transactional bool
}

// ApplyPostgresMigrations upgrades a database to the embedded schema catalog.
// It is intentionally separate from NewPostgres so serving startup never
// mutates schema or data.
func ApplyPostgresMigrations(
	ctx context.Context,
	databaseURL string,
	options MigrationOptions,
) (MigrationResult, error) {
	options = options.withDefaults()
	migrations, err := loadMigrations()
	if err != nil {
		return MigrationResult{}, err
	}

	conn, err := pgx.Connect(ctx, databaseURL)
	if err != nil {
		return MigrationResult{}, fmt.Errorf("store: connect migration database: %w", err)
	}
	defer func() { _ = conn.Close(context.Background()) }()

	if err := configureMigrationTimeouts(ctx, conn, options); err != nil {
		return MigrationResult{}, err
	}
	if err := acquireMigrationLock(ctx, conn, options.LockTimeout); err != nil {
		return MigrationResult{}, err
	}
	defer releaseMigrationLock(conn)

	applied, metadataExists, err := readAppliedMigrations(ctx, conn)
	if err != nil {
		return MigrationResult{}, err
	}
	if err := validateAppliedMigrations(applied, migrations); err != nil {
		return MigrationResult{}, err
	}
	if err := authorizeMigrationStart(ctx, conn, applied, metadataExists, options.AdoptLegacy); err != nil {
		return MigrationResult{}, err
	}

	appliedByVersion := make(map[int64]appliedMigration, len(applied))
	for _, item := range applied {
		appliedByVersion[item.Version] = item
	}

	result := MigrationResult{}
	for _, m := range migrations {
		if _, ok := appliedByVersion[m.Version]; ok {
			result.DatabaseVersion = m.Version
			continue
		}
		if err := applyMigration(ctx, conn, m, metadataExists); err != nil {
			return result, err
		}
		metadataExists = true
		result.DatabaseVersion = m.Version
		result.Applied = append(result.Applied, m.Version)
	}
	if err := validateCriticalSchemaShape(ctx, conn, result.DatabaseVersion); err != nil {
		return result, fmt.Errorf("store: validate final migrated schema: %w", err)
	}
	return result, nil
}

func authorizeMigrationStart(
	ctx context.Context,
	conn *pgx.Conn,
	applied []appliedMigration,
	metadataExists bool,
	adoptLegacy bool,
) error {
	if metadataExists {
		if len(applied) == 0 {
			if err := validateBootstrapRetryState(ctx, conn); err != nil {
				return fmt.Errorf("store: refusing incomplete schema bootstrap: %w", err)
			}
		}
		return nil
	}

	empty, err := schemaIsEmpty(ctx, conn)
	if err != nil {
		return err
	}
	if empty {
		return nil
	}
	if err := validateLegacySchemaFingerprint(ctx, conn); err != nil {
		return fmt.Errorf(
			"store: refusing unversioned nonempty database: Darkbloom legacy fingerprint mismatch: %w",
			err,
		)
	}
	if !adoptLegacy {
		return errors.New(
			"store: recognized an unversioned Darkbloom legacy database; " +
				"rerun coordinator-migrate with -adopt-legacy to adopt it explicitly",
		)
	}
	return nil
}

func (o MigrationOptions) withDefaults() MigrationOptions {
	if o.LockTimeout <= 0 {
		o.LockTimeout = DefaultMigrationLockTimeout
	}
	if o.StatementTimeout <= 0 {
		o.StatementTimeout = DefaultMigrationStatementTimeout
	}
	return o
}

func configureMigrationTimeouts(
	ctx context.Context,
	conn *pgx.Conn,
	options MigrationOptions,
) error {
	if _, err := conn.Exec(
		ctx,
		`SELECT set_config('lock_timeout', $1, false),
		        set_config('statement_timeout', $2, false)`,
		postgresDuration(options.LockTimeout),
		postgresDuration(options.StatementTimeout),
	); err != nil {
		return fmt.Errorf("store: configure migration timeouts: %w", err)
	}
	return nil
}

func postgresDuration(duration time.Duration) string {
	milliseconds := duration.Milliseconds()
	if milliseconds < 1 {
		milliseconds = 1
	}
	return fmt.Sprintf("%dms", milliseconds)
}

func acquireMigrationLock(ctx context.Context, conn *pgx.Conn, timeout time.Duration) error {
	lockCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	for {
		var acquired bool
		if err := conn.QueryRow(
			lockCtx,
			`SELECT pg_try_advisory_lock(hashtextextended($1, 0))`,
			migrationAdvisoryLockKey,
		).Scan(&acquired); err != nil {
			if errors.Is(lockCtx.Err(), context.DeadlineExceeded) {
				return fmt.Errorf("store: migration advisory lock timeout after %s", timeout)
			}
			return fmt.Errorf("store: acquire migration advisory lock: %w", err)
		}
		if acquired {
			return nil
		}

		timer := time.NewTimer(100 * time.Millisecond)
		select {
		case <-lockCtx.Done():
			timer.Stop()
			if errors.Is(lockCtx.Err(), context.DeadlineExceeded) {
				return fmt.Errorf("store: migration advisory lock timeout after %s", timeout)
			}
			return fmt.Errorf("store: acquire migration advisory lock: %w", lockCtx.Err())
		case <-timer.C:
		}
	}
}

func releaseMigrationLock(conn *pgx.Conn) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var released bool
	_ = conn.QueryRow(
		ctx,
		`SELECT pg_advisory_unlock(hashtextextended($1, 0))`,
		migrationAdvisoryLockKey,
	).Scan(&released)
}

func applyMigration(
	ctx context.Context,
	conn *pgx.Conn,
	m migration,
	metadataExists bool,
) error {
	statements, err := splitSQLStatements(m.SQL)
	if err != nil {
		return fmt.Errorf("store: parse migration %06d_%s: %w", m.Version, m.Name, err)
	}
	if len(statements) == 0 {
		return fmt.Errorf("store: migration %06d_%s has no SQL statements", m.Version, m.Name)
	}

	if m.Transactional {
		tx, err := conn.Begin(ctx)
		if err != nil {
			return fmt.Errorf("store: begin migration %06d_%s: %w", m.Version, m.Name, err)
		}
		defer func() { _ = tx.Rollback(context.Background()) }()
		if err := executeMigrationStatements(ctx, tx, m, statements); err != nil {
			return err
		}
		if err := validateCriticalSchemaShape(ctx, tx, m.Version); err != nil {
			return fmt.Errorf("store: validate migration %06d_%s: %w", m.Version, m.Name, err)
		}
		if err := insertAppliedMigration(ctx, tx, m); err != nil {
			return err
		}
		if err := tx.Commit(ctx); err != nil {
			return fmt.Errorf("store: commit migration %06d_%s: %w", m.Version, m.Name, err)
		}
		return nil
	}

	if !metadataExists && !m.Bootstrap {
		return fmt.Errorf(
			"store: nontransactional migration %06d_%s cannot run before metadata exists",
			m.Version,
			m.Name,
		)
	}
	if m.ConcurrentIndex != "" {
		matches, err := concurrentIndexDefinitionMatches(ctx, conn, m.ConcurrentIndex)
		if err != nil {
			return fmt.Errorf("store: inspect concurrent index %s: %w", m.ConcurrentIndex, err)
		}
		if matches {
			if err := validateCriticalSchemaShape(ctx, conn, m.Version); err != nil {
				return fmt.Errorf("store: validate migration %06d_%s: %w", m.Version, m.Name, err)
			}
			return insertAppliedMigration(ctx, conn, m)
		}
	}
	if err := executeMigrationStatements(ctx, conn, m, statements); err != nil {
		return err
	}
	if err := validateCriticalSchemaShape(ctx, conn, m.Version); err != nil {
		return fmt.Errorf("store: validate migration %06d_%s: %w", m.Version, m.Name, err)
	}
	return insertAppliedMigration(ctx, conn, m)
}

type migrationExecutor interface {
	Exec(context.Context, string, ...any) (pgconn.CommandTag, error)
}

func executeMigrationStatements(
	ctx context.Context,
	executor migrationExecutor,
	m migration,
	statements []string,
) error {
	for i, statement := range statements {
		if _, err := executor.Exec(ctx, statement); err != nil {
			return fmt.Errorf(
				"store: migration %06d_%s statement %d/%d: %w",
				m.Version,
				m.Name,
				i+1,
				len(statements),
				err,
			)
		}
	}
	return nil
}

func insertAppliedMigration(
	ctx context.Context,
	executor migrationExecutor,
	m migration,
) error {
	if _, err := executor.Exec(
		ctx,
		`INSERT INTO schema_migration_versions
		    (version, name, checksum, transactional)
		 VALUES ($1, $2, $3, $4)`,
		m.Version,
		m.Name,
		m.Checksum,
		m.Transactional,
	); err != nil {
		return fmt.Errorf("store: record migration %06d_%s: %w", m.Version, m.Name, err)
	}
	return nil
}
