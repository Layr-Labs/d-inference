package store

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestPostgresFullMigrateSerializesProviderEarningsIndexRepair(t *testing.T) {
	databaseURL := newWithdrawableTestDatabase(t)
	setupCtx, setupCancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer setupCancel()

	bootstrap, err := NewPostgres(setupCtx, Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatalf("bootstrap throwaway database: %v", err)
	}
	bootstrap.Close()

	first := newWithdrawableMigrationStore(t, databaseURL)
	second := newWithdrawableMigrationStore(t, databaseURL)
	forceInvalidProviderEarningsJobIndex(t, first)
	installProviderEarningsIndexRaceBarrier(t, first)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	start := make(chan struct{})
	results := make(chan struct {
		replica string
		err     error
	}, 2)
	for replica, migrationStore := range map[string]*PostgresStore{
		"first":  first,
		"second": second,
	} {
		go func() {
			<-start
			results <- struct {
				replica string
				err     error
			}{replica: replica, err: migrationStore.migrate(ctx)}
		}()
	}
	close(start)

	var failures []string
	for range 2 {
		select {
		case result := <-results:
			if result.err != nil {
				failures = append(failures, fmt.Sprintf("%s: %v", result.replica, result.err))
			}
		case <-ctx.Done():
			t.Fatalf("concurrent full migrations did not complete: %v", ctx.Err())
		}
	}
	if len(failures) > 0 {
		t.Fatalf("concurrent full migrations failed:\n%s", strings.Join(failures, "\n"))
	}
	if !jobIndexValid(t, first) {
		t.Fatal("idx_provider_earnings_job missing or invalid after concurrent full migrations")
	}
}

func forceInvalidProviderEarningsJobIndex(t *testing.T, s *PostgresStore) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if _, err := s.pool.Exec(ctx, `
		DROP INDEX idx_provider_earnings_job;
		INSERT INTO provider_earnings (
			account_id, provider_id, provider_key, job_id, model, amount_micro_usd
		) VALUES
			('race-account-1', 'race-provider-1', 'race-key-1', 'duplicate-race-job', 'race-model', 1),
			('race-account-2', 'race-provider-2', 'race-key-2', 'duplicate-race-job', 'race-model', 1)`); err != nil {
		t.Fatalf("prepare duplicate provider earnings: %v", err)
	}

	conn, err := s.pool.Acquire(ctx)
	if err != nil {
		t.Fatalf("acquire invalid-index fixture connection: %v", err)
	}
	build := conn.Conn().PgConn().Exec(ctx,
		`CREATE UNIQUE INDEX CONCURRENTLY idx_provider_earnings_job ON provider_earnings(job_id) WHERE job_id <> ''`)
	_, buildErr := build.ReadAll()
	conn.Release()
	if buildErr == nil {
		t.Fatal("duplicate fixture unexpectedly produced a valid unique index")
	}
	if _, err := s.pool.Exec(ctx,
		`DELETE FROM provider_earnings WHERE job_id = 'duplicate-race-job'`); err != nil {
		t.Fatalf("remove duplicate provider earnings fixture: %v", err)
	}

	var exists, valid bool
	if err := s.pool.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM pg_class c
			JOIN pg_index i ON i.indexrelid = c.oid
			WHERE c.relname = 'idx_provider_earnings_job'
		), COALESCE((
			SELECT i.indisvalid FROM pg_class c
			JOIN pg_index i ON i.indexrelid = c.oid
			WHERE c.relname = 'idx_provider_earnings_job'
		), false)`).Scan(&exists, &valid); err != nil {
		t.Fatalf("inspect invalid provider earnings index fixture: %v", err)
	}
	if !exists || valid {
		t.Fatalf("invalid-index fixture exists=%t valid=%t, want true/false", exists, valid)
	}
}

func installProviderEarningsIndexRaceBarrier(t *testing.T, s *PostgresStore) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if _, err := s.pool.Exec(ctx, `
		CREATE SEQUENCE provider_earnings_drop_race_arrivals;
		CREATE SEQUENCE provider_earnings_create_race_arrivals;
		CREATE FUNCTION synchronize_provider_earnings_index_race()
		RETURNS event_trigger LANGUAGE plpgsql AS $$
		DECLARE
			command_text TEXT := current_query();
			observed BIGINT;
			deadline TIMESTAMPTZ := clock_timestamp() + INTERVAL '2 seconds';
		BEGIN
			IF position(
				'DROP INDEX IF EXISTS idx_provider_earnings_job' IN command_text
			) > 0 THEN
				PERFORM nextval('provider_earnings_drop_race_arrivals');
				LOOP
					SELECT last_value
					INTO observed
					FROM provider_earnings_drop_race_arrivals;
					EXIT WHEN observed >= 2 OR clock_timestamp() >= deadline;
					PERFORM pg_sleep(0.005);
				END LOOP;
			ELSIF position(
				'CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS idx_provider_earnings_job' IN command_text
			) > 0 THEN
				PERFORM nextval('provider_earnings_create_race_arrivals');
				LOOP
					SELECT last_value
					INTO observed
					FROM provider_earnings_create_race_arrivals;
					EXIT WHEN observed >= 2 OR clock_timestamp() >= deadline;
					PERFORM pg_sleep(0.005);
				END LOOP;
			END IF;
		END $$;
		CREATE EVENT TRIGGER synchronize_provider_earnings_index_race
		ON ddl_command_start
		WHEN TAG IN ('DROP INDEX', 'CREATE INDEX')
		EXECUTE FUNCTION synchronize_provider_earnings_index_race()`); err != nil {
		t.Fatalf("install provider earnings index race barrier: %v", err)
	}
}
