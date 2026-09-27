package store

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

type earningsSummaryMigrationDB interface {
	BeginTx(context.Context, pgx.TxOptions) (pgx.Tx, error)
	Exec(context.Context, string, ...any) (pgconn.CommandTag, error)
	QueryRow(context.Context, string, ...any) pgx.Row
}

const earningsSummaryPlanAttemptID = "attempt_earnings_summary_backfill_v1"
const earningsSummaryPlanID = "prepare_earnings_summary_backfill_v1"
const earningsSummaryBackfillPendingDDL = `CREATE TABLE IF NOT EXISTS earnings_summary_backfill_pending (
 key TEXT NOT NULL, key_type TEXT NOT NULL,
 total_count BIGINT NOT NULL, total_micro_usd BIGINT NOT NULL,
 total_prompt_tokens BIGINT NOT NULL, total_completion_tokens BIGINT NOT NULL,
 PRIMARY KEY (key, key_type)
)`

// Both key types use the REPEATABLE READ snapshot pinned before the durable
// attempted-plan marker is written. Old atomic earning/summary writers committing
// after that boundary are absent from both reads; their increments coexist with
// the captured history when its delta is applied later. Counters already present
// at the pinned boundary are preserved, not reconstructed or repaired.
// Legacy record-only/import writers must be quiesced during preparation.
const planEarningsSummaryBackfill = `WITH missing_history AS MATERIALIZED (
 SELECT e.account_id AS key, 'account' AS key_type,
  COUNT(*) FILTER (WHERE e.model <> 'base_reward') AS total_count,
  COALESCE(SUM(e.amount_micro_usd),0) AS total_micro_usd,
  COALESCE(SUM(e.prompt_tokens) FILTER (WHERE e.model <> 'base_reward'),0) AS total_prompt_tokens,
  COALESCE(SUM(e.completion_tokens) FILTER (WHERE e.model <> 'base_reward'),0) AS total_completion_tokens
 FROM provider_earnings e
 WHERE e.account_id <> '' AND NOT EXISTS (
  SELECT 1 FROM earnings_summary s WHERE s.key=e.account_id AND s.key_type='account')
 GROUP BY e.account_id
 UNION ALL
 SELECT e.provider_key, 'provider', COUNT(*) FILTER (WHERE e.model <> 'base_reward'),
  COALESCE(SUM(e.amount_micro_usd),0),
  COALESCE(SUM(e.prompt_tokens) FILTER (WHERE e.model <> 'base_reward'),0),
  COALESCE(SUM(e.completion_tokens) FILTER (WHERE e.model <> 'base_reward'),0)
 FROM provider_earnings e
 WHERE e.provider_key <> '' AND NOT EXISTS (
  SELECT 1 FROM earnings_summary s WHERE s.key=e.provider_key AND s.key_type='provider')
 GROUP BY e.provider_key
)
INSERT INTO earnings_summary_backfill_pending
 SELECT key,key_type,total_count,total_micro_usd,total_prompt_tokens,total_completion_tokens FROM missing_history`

// claimAttempt must commit through a separate connection, outside the pinned
// planning transaction, so its marker survives cancellation or plan rollback.
func prepareEarningsSummaryBackfill(ctx context.Context, db earningsSummaryMigrationDB, claimAttempt func(context.Context) (bool, error)) error {
	var ready, attempted bool
	if err := db.QueryRow(ctx, `SELECT
  EXISTS(SELECT 1 FROM schema_migrations WHERE id=$1),
  EXISTS(SELECT 1 FROM schema_migrations WHERE id=$2)`, earningsSummaryPlanID, earningsSummaryPlanAttemptID).Scan(&ready, &attempted); err != nil {
		return err
	}
	if ready {
		return nil
	}
	if attempted {
		return fmt.Errorf("store: earnings summary initial plan is incomplete; quiesce writers and reconcile existing summaries before explicitly resetting the attempted-plan marker")
	}
	tx, err := db.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	// BEGIN alone does not establish a PostgreSQL snapshot. Pin it explicitly
	// before any writer can observe the attempted marker. The ID is not logged.
	var snapshot string
	if err := tx.QueryRow(ctx, `SELECT pg_current_snapshot()::text`).Scan(&snapshot); err != nil {
		return fmt.Errorf("store: pin earnings summary snapshot: %w", err)
	}
	claimed, err := claimAttempt(ctx)
	if err != nil {
		return fmt.Errorf("store: earnings attempted-marker write failed or is uncertain; pinned plan was not applied: %w", err)
	}
	if !claimed {
		return fmt.Errorf("store: earnings attempted-marker already claimed; pinned plan was not applied")
	}
	tag, err := tx.Exec(ctx, `INSERT INTO schema_migrations(id) VALUES($1) ON CONFLICT(id) DO NOTHING`, earningsSummaryPlanID)
	if err != nil {
		return fmt.Errorf("store: claim earnings summary plan: %w", err)
	}
	if tag.RowsAffected() != 1 {
		return fmt.Errorf("store: earnings ready-plan marker appeared during planning; pinned plan was not applied")
	}
	if _, err := tx.Exec(ctx, planEarningsSummaryBackfill); err != nil {
		return fmt.Errorf("store: plan earnings summary backfill: %w", err)
	}
	return tx.Commit(ctx)
}

// A single-key update cannot hold an account row while waiting on a provider
// row (or vice versa), avoiding a lock cycle with old serving writers. Applying
// the delta and removing its pending item are atomic, so cancellation/crash can
// resume without dropping history or double-counting a previously applied key.
func applyNextEarningsSummaryBackfill(ctx context.Context, db earningsSummaryMigrationDB) (bool, error) {
	tag, err := db.Exec(ctx, `WITH pending AS MATERIALIZED (
  SELECT * FROM earnings_summary_backfill_pending ORDER BY key,key_type LIMIT 1 FOR UPDATE
 ), applied AS (
  INSERT INTO earnings_summary(key,key_type,total_count,total_micro_usd,total_prompt_tokens,total_completion_tokens,updated_at)
  SELECT key,key_type,total_count,total_micro_usd,total_prompt_tokens,total_completion_tokens,NOW() FROM pending
  ON CONFLICT(key,key_type) DO UPDATE SET
   total_count=earnings_summary.total_count+EXCLUDED.total_count,
   total_micro_usd=earnings_summary.total_micro_usd+EXCLUDED.total_micro_usd,
   total_prompt_tokens=earnings_summary.total_prompt_tokens+EXCLUDED.total_prompt_tokens,
   total_completion_tokens=earnings_summary.total_completion_tokens+EXCLUDED.total_completion_tokens,
   updated_at=NOW()
  RETURNING key,key_type
 ) DELETE FROM earnings_summary_backfill_pending p USING applied a WHERE p.key=a.key AND p.key_type=a.key_type`)
	if err != nil {
		return false, fmt.Errorf("store: apply earnings summary history: %w", err)
	}
	return tag.RowsAffected() > 0, nil
}
