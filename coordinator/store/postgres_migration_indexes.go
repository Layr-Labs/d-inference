package store

import (
	"context"
	"database/sql"
	"fmt"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/pressly/goose/v3"
)

// A CONCURRENTLY build blocks no reads or writes, but it waits for every
// older snapshot in the database. The 3 s session lock_timeout of the SQL
// migrations would cancel it behind any longer query, so index migrations
// wait up to a minute.
const concurrentIndexLockTimeout = time.Minute

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
		index(6, "idx_provider_sessions_account", `CREATE INDEX CONCURRENTLY idx_provider_sessions_account ON provider_sessions (account_id)`),
		index(7, "idx_provider_log_reports_account", `CREATE INDEX CONCURRENTLY idx_provider_log_reports_account ON provider_log_reports (account_id)`),
		index(8, "idx_device_codes_account", `CREATE INDEX CONCURRENTLY idx_device_codes_account ON device_codes (account_id)`),
		index(9, "idx_darkbloom_machine_sessions_account", `CREATE INDEX CONCURRENTLY idx_darkbloom_machine_sessions_account ON darkbloom_machine_sessions (account_id)`),
		index(10, "idx_model_token_reservations_account", `CREATE INDEX CONCURRENTLY idx_model_token_reservations_account ON model_token_reservations (account_id)`),
		index(11, "idx_inference_routes_consumer_key_hash", `CREATE INDEX CONCURRENTLY idx_inference_routes_consumer_key_hash ON inference_routes (consumer_key_hash)`),
		index(12, "idx_request_rejections_consumer_key_hash", `CREATE INDEX CONCURRENTLY idx_request_rejections_consumer_key_hash ON request_rejections (consumer_key_hash)`),
		// A Privy user ID is unique among live users only, so the same person
		// can sign up again after an erased account. Versions 15 and 16 drop
		// the old full-table unique constraint and index.
		index(14, "idx_users_privy_live", `CREATE UNIQUE INDEX CONCURRENTLY idx_users_privy_live ON users (privy_user_id) WHERE deleted_at IS NULL`),
		// The erasure scrub replaces a referrer code in the billing sessions
		// that copied it.
		index(19, "idx_billing_sessions_referral_code", `CREATE INDEX CONCURRENTLY idx_billing_sessions_referral_code ON billing_sessions (referral_code) WHERE referral_code <> ''`),
		// A Privy login checks whether a soft-deleted user holds the Privy ID
		// (PrivyUserPendingErasure); idx_users_privy_live does not cover
		// deleted rows.
		index(20, "idx_users_privy_deleted", `CREATE INDEX CONCURRENTLY idx_users_privy_deleted ON users (privy_user_id) WHERE deleted_at IS NOT NULL`),
	}
}

// buildConcurrentIndex builds the index name with ddl on a connection of its
// own. It returns at once when a valid index exists. It drops an invalid
// index left by an interrupted attempt and builds again; the goose advisory
// lock keeps another migration run from building the same index meanwhile.
// It fails unless the index ends up valid, so goose never records the
// version with a broken index.
func (s *PostgresStore) buildConcurrentIndex(ctx context.Context, name, ddl string) error {
	started := time.Now()
	err := s.buildConcurrentIndexOnce(ctx, name, ddl)
	logStartupMigration(name, started, err)
	return err
}

func (s *PostgresStore) buildConcurrentIndexOnce(ctx context.Context, name, ddl string) error {
	cfg := s.pool.Config().ConnConfig
	cfg.RuntimeParams["lock_timeout"] = strconv.FormatInt(concurrentIndexLockTimeout.Milliseconds(), 10)
	conn, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		return fmt.Errorf("store: connect to build index %s: %w", name, err)
	}
	defer conn.Close(context.WithoutCancel(ctx))

	exists, valid, err := concurrentIndexState(ctx, conn, name)
	if err != nil || valid {
		return err
	}
	// CONCURRENTLY runs outside a transaction, so each statement goes through
	// the simple protocol on its own.
	run := func(sql string) error {
		_, err := conn.PgConn().Exec(ctx, sql).ReadAll()
		return err
	}
	if exists {
		if err := run(`DROP INDEX CONCURRENTLY IF EXISTS ` + pgx.Identifier{name}.Sanitize()); err != nil {
			return fmt.Errorf("store: drop invalid index %s: %w", name, err)
		}
	}
	if err := run(ddl); err != nil {
		return fmt.Errorf("store: create index %s: %w", name, err)
	}
	if _, valid, err = concurrentIndexState(ctx, conn, name); err != nil {
		return err
	}
	if !valid {
		return fmt.Errorf("store: index %s did not become valid", name)
	}
	return nil
}

// concurrentIndexState reports whether the index name exists in the current
// schema and whether it is valid and ready.
func concurrentIndexState(ctx context.Context, conn *pgx.Conn, name string) (exists, valid bool, err error) {
	err = conn.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM pg_index WHERE indexrelid = to_regclass(format('%I.%I', current_schema(), $1::text))),
		COALESCE((SELECT indisvalid AND indisready FROM pg_index WHERE indexrelid = to_regclass(format('%I.%I', current_schema(), $1::text))), false)`, name).Scan(&exists, &valid)
	if err != nil {
		err = fmt.Errorf("store: inspect index %s: %w", name, err)
	}
	return exists, valid, err
}
