package store

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
)

const usageTotalsMigrationID = "backfill_usage_totals_v1"

type usageTotalsMigrationResult string

const (
	usageTotalsMigrationBackfilled usageTotalsMigrationResult = "backfilled"
	usageTotalsMigrationPreserved  usageTotalsMigrationResult = "preserved_existing"
	usageTotalsMigrationSkipped    usageTotalsMigrationResult = "already_applied"
)

type usageTotalsMigrationPreparation struct {
	CutoffID int64
	Result   usageTotalsMigrationResult
}

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

// applyUsageTotalsMigration checks the durable marker and counter row before
// touching usage. The old INSERT ... SELECT ... ON CONFLICT statement still
// evaluated the full aggregate before discovering the conflict, so every
// restart scanned all historical usage.
//
// A fresh database uses a two-phase cutover. The prepare transaction briefly
// fences inserts only while it captures the current maximum usage ID, creates
// the zero counter, and persists that cutoff. Writers then resume immediately
// and increment the counter while the historical range is aggregated. The
// finalize transaction atomically adds that range and records completion.
// Interrupted backfills resume from the durable cutoff without double-counting.
func (s *PostgresStore) applyUsageTotalsMigration(ctx context.Context) (usageTotalsMigrationResult, error) {
	preparation, err := s.prepareUsageTotalsMigration(ctx)
	if err != nil {
		return "", err
	}
	if preparation.Result != "" {
		return preparation.Result, nil
	}
	return s.finalizeUsageTotalsMigration(ctx, preparation.CutoffID)
}

func (s *PostgresStore) prepareUsageTotalsMigration(ctx context.Context) (usageTotalsMigrationPreparation, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return usageTotalsMigrationPreparation{}, fmt.Errorf("begin preparation: %w", err)
	}
	defer tx.Rollback(ctx)

	if err := acquireUsageTotalsMigrationLock(ctx, tx); err != nil {
		return usageTotalsMigrationPreparation{}, err
	}

	var applied, counterExists bool
	if err := tx.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE id = $1)`,
		usageTotalsMigrationID,
	).Scan(&applied); err != nil {
		return usageTotalsMigrationPreparation{}, fmt.Errorf("check migration marker: %w", err)
	}
	if err := tx.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM usage_totals WHERE id = 1)`,
	).Scan(&counterExists); err != nil {
		return usageTotalsMigrationPreparation{}, fmt.Errorf("check counter row: %w", err)
	}
	if applied {
		if !counterExists {
			return usageTotalsMigrationPreparation{}, errors.New("migration marked applied but counter row is missing")
		}
		if err := tx.Commit(ctx); err != nil {
			return usageTotalsMigrationPreparation{}, fmt.Errorf("commit skip: %w", err)
		}
		return usageTotalsMigrationPreparation{Result: usageTotalsMigrationSkipped}, nil
	}

	var cutoffID int64
	err = tx.QueryRow(ctx,
		`SELECT cutoff_id FROM usage_totals_backfill_state WHERE id = 1`,
	).Scan(&cutoffID)
	if err == nil {
		if !counterExists {
			return usageTotalsMigrationPreparation{}, errors.New("backfill checkpoint exists but counter row is missing")
		}
		if err := tx.Commit(ctx); err != nil {
			return usageTotalsMigrationPreparation{}, fmt.Errorf("commit resumed preparation: %w", err)
		}
		return usageTotalsMigrationPreparation{CutoffID: cutoffID}, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return usageTotalsMigrationPreparation{}, fmt.Errorf("read backfill checkpoint: %w", err)
	}

	// Databases upgraded from the old inline migration already have an exact
	// counter but no marker. Adopt it without rescanning usage.
	if counterExists {
		if _, err := tx.Exec(ctx,
			`INSERT INTO schema_migrations (id) VALUES ($1)`,
			usageTotalsMigrationID,
		); err != nil {
			return usageTotalsMigrationPreparation{}, fmt.Errorf("mark existing counter: %w", err)
		}
		if err := tx.Commit(ctx); err != nil {
			return usageTotalsMigrationPreparation{}, fmt.Errorf("commit existing counter: %w", err)
		}
		return usageTotalsMigrationPreparation{Result: usageTotalsMigrationPreserved}, nil
	}

	// SHARE waits for existing inserts and prevents new ones only for the
	// constant-time cutoff/counter/checkpoint transaction. The historical scan
	// runs after commit and never holds this writer-conflicting lock.
	if _, err := tx.Exec(ctx, `LOCK TABLE usage IN SHARE MODE`); err != nil {
		return usageTotalsMigrationPreparation{}, fmt.Errorf("fence usage inserts: %w", err)
	}
	if err := tx.QueryRow(ctx, `SELECT COALESCE(MAX(id), 0) FROM usage`).Scan(&cutoffID); err != nil {
		return usageTotalsMigrationPreparation{}, fmt.Errorf("capture usage cutoff: %w", err)
	}
	if _, err := tx.Exec(ctx, `INSERT INTO usage_totals (id) VALUES (1)`); err != nil {
		return usageTotalsMigrationPreparation{}, fmt.Errorf("initialize counter row: %w", err)
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO usage_totals_backfill_state (id, cutoff_id) VALUES (1, $1)`,
		cutoffID,
	); err != nil {
		return usageTotalsMigrationPreparation{}, fmt.Errorf("persist backfill checkpoint: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return usageTotalsMigrationPreparation{}, fmt.Errorf("commit preparation: %w", err)
	}
	return usageTotalsMigrationPreparation{CutoffID: cutoffID}, nil
}

func (s *PostgresStore) finalizeUsageTotalsMigration(
	ctx context.Context,
	expectedCutoffID int64,
) (usageTotalsMigrationResult, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return "", fmt.Errorf("begin finalization: %w", err)
	}
	defer tx.Rollback(ctx)

	if err := acquireUsageTotalsMigrationLock(ctx, tx); err != nil {
		return "", err
	}

	var applied bool
	if err := tx.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE id = $1)`,
		usageTotalsMigrationID,
	).Scan(&applied); err != nil {
		return "", fmt.Errorf("check final migration marker: %w", err)
	}
	if applied {
		if err := tx.Commit(ctx); err != nil {
			return "", fmt.Errorf("commit finalized skip: %w", err)
		}
		return usageTotalsMigrationSkipped, nil
	}

	var cutoffID int64
	if err := tx.QueryRow(ctx,
		`SELECT cutoff_id FROM usage_totals_backfill_state WHERE id = 1`,
	).Scan(&cutoffID); err != nil {
		return "", fmt.Errorf("read final backfill checkpoint: %w", err)
	}
	if cutoffID != expectedCutoffID {
		return "", fmt.Errorf("backfill cutoff changed from %d to %d", expectedCutoffID, cutoffID)
	}

	var requests, promptTokens, completionTokens int64
	if err := tx.QueryRow(ctx, `
		SELECT
			COUNT(*),
			COALESCE(SUM(prompt_tokens), 0),
			COALESCE(SUM(completion_tokens), 0)
		FROM usage
		WHERE id <= $1`,
		cutoffID,
	).Scan(&requests, &promptTokens, &completionTokens); err != nil {
		return "", fmt.Errorf("aggregate historical usage: %w", err)
	}
	tag, err := tx.Exec(ctx, `
		UPDATE usage_totals SET
			total_requests = total_requests + $1,
			total_prompt_tokens = total_prompt_tokens + $2,
			total_completion_tokens = total_completion_tokens + $3
		WHERE id = 1`,
		requests, promptTokens, completionTokens,
	)
	if err != nil {
		return "", fmt.Errorf("apply historical usage: %w", err)
	}
	if tag.RowsAffected() != 1 {
		return "", fmt.Errorf("apply historical usage: updated %d rows, want 1", tag.RowsAffected())
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO schema_migrations (id) VALUES ($1)`,
		usageTotalsMigrationID,
	); err != nil {
		return "", fmt.Errorf("record migration marker: %w", err)
	}
	tag, err = tx.Exec(ctx, `DELETE FROM usage_totals_backfill_state WHERE id = 1`)
	if err != nil {
		return "", fmt.Errorf("clear backfill checkpoint: %w", err)
	}
	if tag.RowsAffected() != 1 {
		return "", fmt.Errorf("clear backfill checkpoint: deleted %d rows, want 1", tag.RowsAffected())
	}
	if err := tx.Commit(ctx); err != nil {
		return "", fmt.Errorf("commit finalization: %w", err)
	}
	return usageTotalsMigrationBackfilled, nil
}

func acquireUsageTotalsMigrationLock(ctx context.Context, tx pgx.Tx) error {
	if _, err := tx.Exec(ctx, `
		SELECT pg_advisory_xact_lock(
			hashtext(current_schema()),
			hashtext($1)
		)`,
		usageTotalsMigrationID,
	); err != nil {
		return fmt.Errorf("acquire migration lock: %w", err)
	}
	return nil
}
