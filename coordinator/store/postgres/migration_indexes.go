package postgres

import (
	"context"
	"database/sql"
	"fmt"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/pressly/goose/v3"
)

// indexMigrations build one index each, CONCURRENTLY, as Go migrations: an
// SQL file cannot check that the index it built is valid.
func (s *PostgresStore) indexMigrations() []*goose.Migration {
	index := func(version int64, name, ddl string) *goose.Migration {
		return goose.NewGoMigration(version, &goose.GoFunc{
			RunDB: func(ctx context.Context, _ *sql.DB) error { return s.buildConcurrentIndex(ctx, name, ddl) },
		}, nil)
	}
	return []*goose.Migration{
		// Account erasure finds rows by these columns.
		index(10, "idx_provider_sessions_account", `CREATE INDEX CONCURRENTLY idx_provider_sessions_account ON provider_sessions (account_id)`),
		index(11, "idx_provider_log_reports_account", `CREATE INDEX CONCURRENTLY idx_provider_log_reports_account ON provider_log_reports (account_id)`),
		index(12, "idx_device_codes_account", `CREATE INDEX CONCURRENTLY idx_device_codes_account ON device_codes (account_id)`),
		index(13, "idx_darkbloom_machine_sessions_account", `CREATE INDEX CONCURRENTLY idx_darkbloom_machine_sessions_account ON darkbloom_machine_sessions (account_id)`),
		index(14, "idx_model_token_reservations_account", `CREATE INDEX CONCURRENTLY idx_model_token_reservations_account ON model_token_reservations (account_id)`),
		index(15, "idx_inference_routes_consumer_key_hash", `CREATE INDEX CONCURRENTLY idx_inference_routes_consumer_key_hash ON inference_routes (consumer_key_hash)`),
		index(16, "idx_request_rejections_consumer_key_hash", `CREATE INDEX CONCURRENTLY idx_request_rejections_consumer_key_hash ON request_rejections (consumer_key_hash)`),
		// A Privy user ID is unique among live users only, so the same person
		// can sign up again after an erased account. Versions 19 and 20 drop
		// the old full-table unique constraint and index.
		index(18, "idx_users_privy_live", `CREATE UNIQUE INDEX CONCURRENTLY idx_users_privy_live ON users (privy_user_id) WHERE deleted_at IS NULL`),
		// The erasure scrub replaces a referrer code in the billing sessions
		// that copied it.
		index(23, "idx_billing_sessions_referral_code", `CREATE INDEX CONCURRENTLY idx_billing_sessions_referral_code ON billing_sessions (referral_code) WHERE referral_code <> ''`),
		// A Privy login checks whether a soft-deleted user holds the Privy ID
		// (PrivyUserPendingErasure); idx_users_privy_live does not cover
		// deleted rows.
		index(24, "idx_users_privy_deleted", `CREATE INDEX CONCURRENTLY idx_users_privy_deleted ON users (privy_user_id) WHERE deleted_at IS NOT NULL`),
	}
}

// buildConcurrentIndex records the startup timing for a single-index migration.
func (s *PostgresStore) buildConcurrentIndex(ctx context.Context, name, ddl string) error {
	started := time.Now()
	err := s.ensureConcurrentIndex(ctx, name, ddl)
	logStartupMigration(name, started, err)
	return err
}

// ensureConcurrentIndex builds a missing index on a dedicated connection and
// requires it to be valid and ready. An invalid index requires operator
// inspection: a builder outside goose may still be working on it.
func (s *PostgresStore) ensureConcurrentIndex(ctx context.Context, name, ddl string) error {
	cfg := s.pool.Config().ConnConfig
	// Concurrent builds wait for older snapshots, independently of the short
	// ordinary DDL lock timeout. Do not change timeouts on the serving pool.
	cfg.RuntimeParams["lock_timeout"] = strconv.FormatInt(s.concurrentIndexLockTimeout.Milliseconds(), 10)
	conn, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		return fmt.Errorf("store: connect to build index %s: %w", name, err)
	}
	defer conn.Close(ctx)

	exists, valid, err := concurrentIndexState(ctx, conn, name)
	if err != nil || valid {
		return err
	}
	if exists {
		return invalidConcurrentIndexError(name)
	}
	// CONCURRENTLY runs outside a transaction, through the simple protocol.
	if _, err := conn.PgConn().Exec(ctx, ddl).ReadAll(); err != nil {
		return fmt.Errorf("store: create index %s: %w", name, err)
	}
	if _, valid, err = concurrentIndexState(ctx, conn, name); err != nil {
		return err
	}
	if !valid {
		return invalidConcurrentIndexError(name)
	}
	return nil
}

// concurrentIndexState reports whether the index name exists in the current
// schema and whether it is valid and ready.
func concurrentIndexState(ctx context.Context, conn interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}, name string) (exists, valid bool, err error) {
	err = conn.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM pg_index WHERE indexrelid = to_regclass(format('%I.%I', current_schema(), $1::text))),
		COALESCE((SELECT indisvalid AND indisready FROM pg_index WHERE indexrelid = to_regclass(format('%I.%I', current_schema(), $1::text))), false)`, name).Scan(&exists, &valid)
	if err != nil {
		err = fmt.Errorf("store: inspect index %s: %w", name, err)
	}
	return exists, valid, err
}

func invalidConcurrentIndexError(name string) error {
	return fmt.Errorf("store: index %s is invalid or not ready in the current schema; preserved without changes; "+
		"inspect pg_stat_progress_create_index and pg_stat_activity for an active build and wait for it to finish; "+
		"only after confirming no build is active, have an operator repair or drop the invalid index and retry migrations", name)
}
