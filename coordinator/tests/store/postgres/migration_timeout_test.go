package postgres_test

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	production "github.com/eigeninference/d-inference/coordinator/store/postgres"
	"github.com/jackc/pgx/v5"
)

var concurrentMigrationIndexes = []string{
	"idx_providers_restore_serial", "idx_providers_restore_se_key",
	"idx_provider_earnings_job", "idx_provider_earnings_created_at_brin", "idx_ledger_stripe_refund",
	"idx_provider_sessions_account", "idx_provider_log_reports_account", "idx_device_codes_account",
	"idx_darkbloom_machine_sessions_account", "idx_model_token_reservations_account",
	"idx_inference_routes_consumer_key_hash", "idx_request_rejections_consumer_key_hash",
	"idx_users_privy_live", "idx_billing_sessions_referral_code", "idx_users_privy_deleted",
	"global_payout_funding_reconcile",
}

// Observe settings on the actual DDL connections, not a copy of the timeout
// calculation. This covers every legacy and newer concurrent index builder.
func TestConcurrentIndexMigrationTimeoutIsolation(t *testing.T) {
	for _, tc := range []struct {
		name                string
		urlSettings         string
		lockTimeout         time.Duration
		indexLockMS         int
		indexStatementMS    int
		ordinaryLockMS      int
		ordinaryStatementMS int
	}{
		{name: "programmatic_zero_defaults", indexLockMS: 60000, ordinaryLockMS: 3000, ordinaryStatementMS: 600000},
		{name: "configured_overrides_url_lock_only", urlSettings: "&lock_timeout=17ms&statement_timeout=29s",
			lockTimeout: 1250 * time.Millisecond, indexLockMS: 1250, indexStatementMS: 29000, ordinaryLockMS: 17, ordinaryStatementMS: 29000},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx := context.Background()
			db := newThrowawayTestDatabase(t)
			s, err := openPostgresFixture(ctx, store.Config{DatabaseURL: db})
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(s.Close)
			for _, name := range concurrentMigrationIndexes {
				if _, err := s.pool.Exec(ctx, `DROP INDEX `+pgx.Identifier{name}.Sanitize()); err != nil {
					t.Fatal(err)
				}
			}
			pendingFrom(t, s, 3)
			if _, err := s.pool.Exec(ctx, `
				CREATE TABLE migration_settings (tag text, identity text, lock_ms int, statement_ms int, pid int);
				CREATE FUNCTION capture_migration_settings() RETURNS event_trigger LANGUAGE plpgsql AS $$
				BEGIN
					INSERT INTO migration_settings
					SELECT command_tag, object_identity,
						(extract(epoch FROM current_setting('lock_timeout')::interval) * 1000)::int,
						(extract(epoch FROM current_setting('statement_timeout')::interval) * 1000)::int,
						pg_backend_pid()
					FROM pg_event_trigger_ddl_commands();
				END $$;
				CREATE EVENT TRIGGER migration_settings_trigger ON ddl_command_end
				WHEN TAG IN ('CREATE INDEX', 'ALTER TABLE') EXECUTE FUNCTION capture_migration_settings()`); err != nil {
				t.Fatal(err)
			}
			migrated, err := production.NewPostgres(ctx, store.Config{DatabaseURL: db + tc.urlSettings, ConcurrentIndexLockTimeout: tc.lockTimeout})
			if err != nil {
				t.Fatal(err)
			}
			migrated.Close()
			for _, name := range concurrentMigrationIndexes {
				var count, lockMS, statementMS int
				if err := s.pool.QueryRow(ctx, `SELECT count(*), min(lock_ms), min(statement_ms)
					FROM migration_settings WHERE tag = 'CREATE INDEX' AND identity = 'public.' || $1`, name).Scan(&count, &lockMS, &statementMS); err != nil {
					t.Fatalf("%s settings: %v", name, err)
				}
				if count != 1 || lockMS != tc.indexLockMS || statementMS != tc.indexStatementMS {
					t.Errorf("%s builds=%d lock=%d statement=%d, want 1/%d/%d", name, count, lockMS, statementMS, tc.indexLockMS, tc.indexStatementMS)
				}
				if valid, err := indexValid(ctx, s.pool, name); err != nil || !valid {
					t.Fatalf("%s valid=%v: %v", name, valid, err)
				}
			}
			var ordinaryCount, wrongSettings, reusedConnections int
			if err := s.pool.QueryRow(ctx, `SELECT count(*), count(*) FILTER (WHERE lock_ms <> $1 OR statement_ms <> $2)
				FROM migration_settings WHERE tag = 'ALTER TABLE'`, tc.ordinaryLockMS, tc.ordinaryStatementMS).Scan(&ordinaryCount, &wrongSettings); err != nil {
				t.Fatal(err)
			}
			if ordinaryCount == 0 || wrongSettings != 0 {
				t.Errorf("ordinary migration DDL count=%d, wrong settings=%d", ordinaryCount, wrongSettings)
			}
			if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM migration_settings i JOIN migration_settings d USING (pid)
				WHERE i.tag = 'CREATE INDEX' AND d.tag = 'ALTER TABLE'`).Scan(&reusedConnections); err != nil {
				t.Fatal(err)
			}
			if reusedConnections != 0 {
				t.Fatal("concurrent index builds reused an ordinary migration connection")
			}
		})
	}
}

func TestConcurrentIndexMigrationValidFastPath(t *testing.T) {
	ctx := context.Background()
	s, err := openPostgresFixture(ctx, store.Config{DatabaseURL: newThrowawayTestDatabase(t)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	const indexesSQL = `SELECT indexrelid::text || ' ' || pg_get_indexdef(indexrelid) FROM pg_index ORDER BY indexrelid`
	before := queryLines(t, s.pool, indexesSQL)
	pendingFrom(t, s, 3)
	// This old snapshot would block any attempted concurrent rebuild. It does
	// not lock a user table that the ordinary migrations need to alter.
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SELECT count(*) FROM pg_class`); err != nil {
		t.Fatal(err)
	}
	bounded, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := s.reopen(bounded); err != nil {
		t.Fatalf("valid indexes must not rebuild or wait for snapshots: %v", err)
	}
	assertSameLines(t, "before fast path", before, "after fast path", queryLines(t, s.pool, indexesSQL))
	for _, version := range []int64{3, 4, 5, 9, 10, 24} {
		if !versionRecorded(t, s, version) {
			t.Errorf("version %d not recorded after valid fast path", version)
		}
	}
}

func TestConcurrentIndexMigrationConfiguredWaitExpires(t *testing.T) {
	for _, tc := range []struct {
		name    string
		version int64
	}{
		{"idx_provider_earnings_job", 4},
		{"idx_provider_sessions_account", 10},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx := context.Background()
			db := newThrowawayTestDatabase(t)
			s, err := openPostgresFixture(ctx, store.Config{DatabaseURL: db})
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(s.Close)
			if _, err := s.pool.Exec(ctx, `DROP INDEX `+pgx.Identifier{tc.name}.Sanitize()); err != nil {
				t.Fatal(err)
			}
			pendingFrom(t, s, tc.version)
			tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
			if err != nil {
				t.Fatal(err)
			}
			defer tx.Rollback(ctx)
			if _, err := tx.Exec(ctx, `SELECT count(*) FROM pg_class`); err != nil {
				t.Fatal(err)
			}
			bounded, cancel := context.WithTimeout(ctx, 5*time.Second)
			defer cancel()
			migrated, err := production.NewPostgres(bounded, store.Config{DatabaseURL: db, ConcurrentIndexLockTimeout: 100 * time.Millisecond})
			if migrated != nil {
				migrated.Close()
			}
			// A lock timeout leaves an invalid index; the retry refuses to
			// disturb it, instead of quietly rebuilding until the outer deadline.
			if err == nil || !strings.Contains(err.Error(), "preserved without changes") {
				t.Fatalf("configured timeout and retry = %v", err)
			}
			if bounded.Err() != nil {
				t.Fatalf("hit outer deadline instead of configured lock timeout: %v", bounded.Err())
			}
			if valid, err := indexValid(ctx, s.pool, tc.name); err != nil || valid || versionRecorded(t, s, tc.version) {
				t.Fatalf("failed index valid=%v err=%v", valid, err)
			}
		})
	}
}
