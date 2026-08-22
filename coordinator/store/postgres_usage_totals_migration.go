package store

import (
	"context"
	"fmt"
	"log/slog"
	"time"
)

const usageTotalsMigrationID = "backfill_usage_totals_v1"

type usageTotalsMigrationResult string

const (
	usageTotalsMigrationBackfilled usageTotalsMigrationResult = "backfilled"
	usageTotalsMigrationSkipped    usageTotalsMigrationResult = "already_applied"
)

// migrateUsageTotals records startup observability around the one-time usage
// aggregation without exposing usage values.
func (s *PostgresStore) migrateUsageTotals(ctx context.Context) error {
	started := time.Now()
	result, err := s.applyUsageTotalsMigration(ctx)
	if err != nil {
		slog.Error("postgres migration failed",
			"migration", usageTotalsMigrationID,
			"result", "failed",
			"duration_ms", time.Since(started).Milliseconds())
		return fmt.Errorf("store: migrate usage totals: %w", err)
	}
	slog.Info("postgres migration completed",
		"migration", usageTotalsMigrationID,
		"result", string(result),
		"duration_ms", time.Since(started).Milliseconds())
	return nil
}

// applyUsageTotalsMigration checks the counter row before touching the usage
// table. The old INSERT ... SELECT ... ON CONFLICT statement still evaluated
// the full aggregate before discovering the conflict, so every restart scanned
// all historical usage.
//
// The transaction-scoped advisory lock serializes concurrent coordinators. On
// the first run, the table lock establishes an exact cutover: existing usage
// writers finish before the aggregate snapshot, while new writers wait until
// the counter row exists and can increment it. Every later startup takes only
// the advisory lock and primary-key existence check.
func (s *PostgresStore) applyUsageTotalsMigration(ctx context.Context) (usageTotalsMigrationResult, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return "", fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback(ctx)

	if _, err := tx.Exec(ctx, `
		SELECT pg_advisory_xact_lock(
			hashtext(current_schema()),
			hashtext($1)
		)`,
		usageTotalsMigrationID,
	); err != nil {
		return "", fmt.Errorf("acquire migration lock: %w", err)
	}

	var exists bool
	if err := tx.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM usage_totals WHERE id = 1)`,
	).Scan(&exists); err != nil {
		return "", fmt.Errorf("check counter row: %w", err)
	}
	if exists {
		if err := tx.Commit(ctx); err != nil {
			return "", fmt.Errorf("commit skip: %w", err)
		}
		return usageTotalsMigrationSkipped, nil
	}

	// Usage inserts take ROW EXCLUSIVE, which conflicts with SHARE. Once this
	// lock is granted, the aggregate includes every committed insert and later
	// inserts wait until the initialized counter row commits.
	if _, err := tx.Exec(ctx, `LOCK TABLE usage IN SHARE MODE`); err != nil {
		return "", fmt.Errorf("lock usage table: %w", err)
	}

	tag, err := tx.Exec(ctx, `
		INSERT INTO usage_totals (
			id,
			total_requests,
			total_prompt_tokens,
			total_completion_tokens
		)
		SELECT
			1,
			COUNT(*),
			COALESCE(SUM(prompt_tokens), 0),
			COALESCE(SUM(completion_tokens), 0)
		FROM usage
		ON CONFLICT (id) DO NOTHING`)
	if err != nil {
		return "", fmt.Errorf("aggregate usage: %w", err)
	}
	if tag.RowsAffected() != 1 {
		return "", fmt.Errorf("initialize counter row: inserted %d rows, want 1", tag.RowsAffected())
	}
	if err := tx.Commit(ctx); err != nil {
		return "", fmt.Errorf("commit backfill: %w", err)
	}
	return usageTotalsMigrationBackfilled, nil
}
