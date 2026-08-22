package store

import (
	"bytes"
	"context"
	"os"
	"sync"
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

	start := make(chan struct{})
	results := make(chan usageTotalsMigrationResult, 2)
	errs := make(chan error, 2)
	var wg sync.WaitGroup
	for _, replica := range []*PostgresStore{first, second} {
		wg.Add(1)
		go func(s *PostgresStore) {
			defer wg.Done()
			<-start
			result, err := s.applyUsageTotalsMigration(context.Background())
			results <- result
			errs <- err
		}(replica)
	}
	close(start)
	wg.Wait()
	close(results)
	close(errs)

	for err := range errs {
		if err != nil {
			t.Fatalf("concurrent migration: %v", err)
		}
	}
	counts := map[usageTotalsMigrationResult]int{}
	for result := range results {
		counts[result]++
	}
	if counts[usageTotalsMigrationBackfilled] != 1 || counts[usageTotalsMigrationSkipped] != 1 {
		t.Fatalf("concurrent results = %v, want one backfill and one skip", counts)
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
