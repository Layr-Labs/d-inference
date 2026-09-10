package store

import (
	"context"
	"fmt"
	"log/slog"
	"time"
)

const earningsSummaryMigrationID = "backfill_earnings_summary_v1"

// Existing counters are preserved at the planning snapshot. Missing history is
// durably staged once, then added to live counters in short per-key transactions.
// The final marker prevents every later boot from scanning earnings history.
func (s *PostgresStore) migrateEarningsSummary(ctx context.Context) error {
	started := time.Now()
	applied, err := s.applyEarningsSummaryMigration(ctx)
	result := "already_applied"
	if applied {
		result = "backfilled_missing_keys"
	}
	if err != nil {
		result = "failed"
	}
	slog.Info("postgres migration completed", "migration", earningsSummaryMigrationID,
		"result", result, "duration_ms", time.Since(started).Milliseconds())
	return err
}

func (s *PostgresStore) applyEarningsSummaryMigration(ctx context.Context) (bool, error) {
	conn, err := s.pool.Acquire(ctx)
	if err != nil {
		return false, err
	}
	defer conn.Release()
	var done bool
	check := func() error {
		return conn.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE id=$1)`, earningsSummaryMigrationID).Scan(&done)
	}
	if err := check(); err != nil {
		return false, err
	}
	if done {
		return false, nil
	}
	// Serialize migration runners on one leased connection (also works with a
	// one-connection pool). Initial planning uses one additional bounded direct
	// connection to commit its marker after pinning the snapshot. Serving writers
	// neither use nor need this advisory
	// lock: their compatibility follows from atomic earning+summary commits.
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		if _, err := conn.Exec(cleanup, `SELECT pg_advisory_unlock(hashtext('darkbloom.earnings-summary-backfill.v1'))`); err != nil {
			// Never return a potentially lock-owning session to the shared pool.
			_ = conn.Conn().Close(cleanup)
		}
	}()
	if _, err := conn.Exec(ctx, `SELECT pg_advisory_lock(hashtext('darkbloom.earnings-summary-backfill.v1'))`); err != nil {
		return false, err
	}
	if err := check(); err != nil {
		return false, err
	}
	if done {
		return false, nil
	}
	if err := prepareEarningsSummaryBackfill(ctx, conn, s.claimEarningsSummaryAttempt); err != nil {
		return false, err
	}
	for {
		applied, err := applyNextEarningsSummaryBackfill(ctx, conn)
		if err != nil {
			return false, err
		}
		if !applied {
			break
		}
	}
	if _, err := conn.Exec(ctx, `INSERT INTO schema_migrations(id) VALUES($1) ON CONFLICT(id) DO NOTHING`, earningsSummaryMigrationID); err != nil {
		return false, fmt.Errorf("store: finish earnings summary migration: %w", err)
	}
	return true, nil
}
