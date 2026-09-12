package store

import (
	"context"
	"fmt"
	"log/slog"
	"time"
)

// Log bounded labels only: SQL and query parameters can contain sensitive data.
func logStartupMigration(name string, started time.Time, err error) {
	result := "applied"
	if err != nil {
		result = "failed"
	}
	slog.Info("postgres startup phase", "phase", name, "result", result,
		"duration_ms", time.Since(started).Milliseconds())
}

func (s *PostgresStore) ensureProviderRestoreIndexes(ctx context.Context) error {
	for _, index := range []struct{ name, ddl string }{
		{"idx_providers_restore_serial", `CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_providers_restore_serial ON providers(serial_number, last_seen DESC, id DESC) WHERE serial_number <> ''`},
		{"idx_providers_restore_se_key", `CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_providers_restore_se_key ON providers(se_public_key, last_seen DESC, id DESC) WHERE se_public_key <> ''`},
	} {
		started := time.Now()
		err := s.ensureProviderRestoreIndex(ctx, index.name, index.ddl)
		logStartupMigration(index.name, started, err)
		if err != nil {
			return err
		}
	}
	return nil
}

func (s *PostgresStore) ensureProviderRestoreIndex(ctx context.Context, name, ddl string) error {
	// Use the current schema, so an index in another schema cannot satisfy the
	// gate. An interrupted concurrent build must not silently bypass readiness.
	var exists, valid bool
	if err := s.pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM pg_index WHERE indexrelid = to_regclass(format('%I.%I', current_schema(), $1::text))),
		COALESCE((SELECT indisvalid AND indisready FROM pg_index WHERE indexrelid = to_regclass(format('%I.%I', current_schema(), $1::text))), false)`, name).Scan(&exists, &valid); err != nil {
		return fmt.Errorf("store: inspect restore index %s: %w", name, err)
	}
	if valid {
		return nil
	}
	if exists {
		return fmt.Errorf("store: restore index %s is invalid; repair the interrupted concurrent index build before retrying", name)
	}
	// One statement via simple protocol, outside a transaction. Only index
	// creation is concurrent; this is not permission to run two serving replicas.
	conn, err := s.pool.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()
	if _, err := conn.Conn().PgConn().Exec(ctx, ddl).ReadAll(); err != nil {
		return fmt.Errorf("store: create restore index %s: %w", name, err)
	}
	if err := conn.QueryRow(ctx, `SELECT indisvalid AND indisready FROM pg_index WHERE indexrelid = to_regclass(format('%I.%I', current_schema(), $1::text))`, name).Scan(&valid); err != nil || !valid {
		return fmt.Errorf("store: restore index %s did not become valid (query error: %v)", name, err)
	}
	return nil
}
