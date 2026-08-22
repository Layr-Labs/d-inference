package store

import (
	"bytes"
	"context"
	"errors"
	"os"
	"testing"
	"time"
)

func TestMigrateNoUngatedUsageTotalsAggregation(t *testing.T) {
	src, err := os.ReadFile("postgres.go")
	if err != nil {
		t.Fatalf("read postgres.go: %v", err)
	}
	if bytes.Contains(src, []byte("INSERT INTO usage_totals")) {
		t.Fatal("usage_totals aggregation must not run in the unconditional startup statement list")
	}
}

func TestUsageTotalsMigrationBackfillsOnceWithoutRescanningUsage(t *testing.T) {
	databaseURL := newWithdrawableTestDatabase(t)
	s := newWithdrawableMigrationStore(t, databaseURL)
	prepareUsageTotalsMigrationSchema(t, s)
	seedUsageForTotalsMigration(t, s, 10, 20)
	seedUsageForTotalsMigration(t, s, 30, 40)

	result, err := s.applyUsageTotalsMigration(context.Background())
	if err != nil {
		t.Fatalf("first migration: %v", err)
	}
	if result != usageTotalsMigrationBackfilled {
		t.Fatalf("first result = %q, want %q", result, usageTotalsMigrationBackfilled)
	}
	assertUsageTotalsMigrationValues(t, s, 2, 40, 60)

	// Hold ACCESS EXCLUSIVE on usage. Any SELECT against it must block, while
	// the already-applied fast path should only inspect usage_totals.
	lockTx, err := s.pool.Begin(context.Background())
	if err != nil {
		t.Fatalf("begin table lock: %v", err)
	}
	defer lockTx.Rollback(context.Background())
	if _, err := lockTx.Exec(context.Background(), `LOCK TABLE usage IN ACCESS EXCLUSIVE MODE`); err != nil {
		t.Fatalf("lock usage: %v", err)
	}

	restartCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	result, err = s.applyUsageTotalsMigration(restartCtx)
	if err != nil {
		t.Fatalf("restart migration touched locked usage table: %v", err)
	}
	if result != usageTotalsMigrationSkipped {
		t.Fatalf("restart result = %q, want %q", result, usageTotalsMigrationSkipped)
	}
	assertUsageTotalsMigrationValues(t, s, 2, 40, 60)
}

func TestUsageTotalsMigrationSerializesConcurrentCoordinators(t *testing.T) {
	databaseURL := newWithdrawableTestDatabase(t)
	first := newWithdrawableMigrationStore(t, databaseURL)
	second := newWithdrawableMigrationStore(t, databaseURL)
	prepareUsageTotalsMigrationSchema(t, first)
	seedUsageForTotalsMigration(t, first, 10, 20)
	seedUsageForTotalsMigration(t, first, 30, 40)

	// Hold the exact migration advisory lock from a separate transaction. A
	// contender must time out at lock acquisition rather than reaching the
	// aggregate, proving the serialization does not depend on goroutine timing.
	lockTx, err := first.pool.Begin(context.Background())
	if err != nil {
		t.Fatalf("begin advisory lock: %v", err)
	}
	defer lockTx.Rollback(context.Background())
	if _, err := lockTx.Exec(context.Background(), `
		SELECT pg_advisory_xact_lock(
			hashtext(current_schema()),
			hashtext($1)
		)`,
		usageTotalsMigrationID,
	); err != nil {
		t.Fatalf("hold advisory lock: %v", err)
	}

	blockedCtx, cancel := context.WithTimeout(context.Background(), 250*time.Millisecond)
	defer cancel()
	if _, err := second.applyUsageTotalsMigration(blockedCtx); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("contending migration error = %v, want context deadline at advisory lock", err)
	}
	if err := lockTx.Commit(context.Background()); err != nil {
		t.Fatalf("release advisory lock: %v", err)
	}

	result, err := first.applyUsageTotalsMigration(context.Background())
	if err != nil || result != usageTotalsMigrationBackfilled {
		t.Fatalf("first migration after lock release = (%q, %v), want backfilled", result, err)
	}
	result, err = second.applyUsageTotalsMigration(context.Background())
	if err != nil || result != usageTotalsMigrationSkipped {
		t.Fatalf("second migration = (%q, %v), want already-applied", result, err)
	}
	assertUsageTotalsMigrationValues(t, first, 2, 40, 60)
}

func prepareUsageTotalsMigrationSchema(t *testing.T, s *PostgresStore) {
	t.Helper()
	for _, statement := range []string{
		`CREATE TABLE usage (
			id BIGSERIAL PRIMARY KEY,
			prompt_tokens INTEGER NOT NULL,
			completion_tokens INTEGER NOT NULL
		)`,
		`CREATE TABLE usage_totals (
			id INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
			total_requests BIGINT NOT NULL DEFAULT 0,
			total_prompt_tokens BIGINT NOT NULL DEFAULT 0,
			total_completion_tokens BIGINT NOT NULL DEFAULT 0
		)`,
	} {
		if _, err := s.pool.Exec(context.Background(), statement); err != nil {
			t.Fatalf("prepare usage totals migration schema: %v", err)
		}
	}
}

func seedUsageForTotalsMigration(t *testing.T, s *PostgresStore, promptTokens, completionTokens int) {
	t.Helper()
	if _, err := s.pool.Exec(context.Background(),
		`INSERT INTO usage (prompt_tokens, completion_tokens) VALUES ($1, $2)`,
		promptTokens, completionTokens,
	); err != nil {
		t.Fatalf("seed usage: %v", err)
	}
}

func assertUsageTotalsMigrationValues(
	t *testing.T,
	s *PostgresStore,
	requests, promptTokens, completionTokens int64,
) {
	t.Helper()
	var gotRequests, gotPromptTokens, gotCompletionTokens int64
	if err := s.pool.QueryRow(context.Background(), `
		SELECT total_requests, total_prompt_tokens, total_completion_tokens
		FROM usage_totals
		WHERE id = 1`,
	).Scan(&gotRequests, &gotPromptTokens, &gotCompletionTokens); err != nil {
		t.Fatalf("read usage totals: %v", err)
	}
	if gotRequests != requests || gotPromptTokens != promptTokens || gotCompletionTokens != completionTokens {
		t.Fatalf(
			"usage totals = (%d, %d, %d), want (%d, %d, %d)",
			gotRequests, gotPromptTokens, gotCompletionTokens,
			requests, promptTokens, completionTokens,
		)
	}
}
