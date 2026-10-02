package store

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

const (
	earningsSummaryBaseRewardMigrationID = "backfill_earnings_summary_base_reward_v1"
	earningsSummaryBaseRewardPlanID      = "prepare_earnings_summary_base_reward_v1"
	earningsSummaryBaseRewardLockKey     = "darkbloom.earnings-summary-base-reward.v1"

	// earningsSummaryBaseRewardBatch bounds each apply transaction. The serving
	// coordinator runs the backfill before it listens, so one round trip per
	// account would add tens of seconds to a deploy with many accounts.
	earningsSummaryBaseRewardBatch = 1000
)

const earningsSummaryBaseRewardPendingDDL = `CREATE TABLE IF NOT EXISTS earnings_summary_base_reward_pending (
 account_id TEXT PRIMARY KEY,
 amount_micro_usd BIGINT NOT NULL
)`

// provider_floor_draws is the settlement record behind every model =
// 'base_reward' earnings row (SettleProviderFloorDraw writes both in one
// statement) and is an order of magnitude smaller than provider_earnings.
// Zero-amount draws never produced an earnings row and are skipped.
const planEarningsSummaryBaseReward = `INSERT INTO earnings_summary_base_reward_pending (account_id, amount_micro_usd)
SELECT account_id, SUM(amount_micro_usd) FROM provider_floor_draws
 WHERE account_id <> '' AND amount_micro_usd > 0 GROUP BY account_id`

// earningsSummaryMigrationDB is the subset of a pooled connection the backfill
// steps use.
type earningsSummaryMigrationDB interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	BeginTx(ctx context.Context, txOptions pgx.TxOptions) (pgx.Tx, error)
}

// BackfillEarningsSummaryBaseReward runs the one-shot base-reward backfill.
// The serving coordinator calls it at startup, before any worker settles
// draws; --migrate-only does not, because a coordinator of the previous
// release can keep settling draws for as long as it serves after this runs.
func (s *PostgresStore) BackfillEarningsSummaryBaseReward(ctx context.Context) error {
	return s.migrateEarningsSummaryBaseReward(ctx)
}

// migrateEarningsSummaryBaseReward fills total_base_reward_micro_usd once with
// the base rewards settled before the column existed; every writer adds new
// ones as they are credited. One planning transaction pins a REPEATABLE READ
// snapshot and commits the per-account totals together with the plan marker,
// the totals are then added and dequeued in short batched transactions so a
// crash resumes without double-adding, and the final marker keeps later boots
// from rescanning. Base rewards a previous coordinator settles after the
// snapshot (during the blue-green handoff, or while a rollback to an earlier
// release serves) are in total_micro_usd but not in this column.
func (s *PostgresStore) migrateEarningsSummaryBaseReward(ctx context.Context) error {
	started := time.Now()
	applied, err := s.applyEarningsSummaryBaseRewardMigration(ctx)
	result := "already_applied"
	if applied {
		result = "backfilled_base_rewards"
	}
	if err != nil {
		result = "failed"
	}
	slog.Info("postgres migration completed", "migration", earningsSummaryBaseRewardMigrationID,
		"result", result, "duration_ms", time.Since(started).Milliseconds())
	return err
}

func (s *PostgresStore) applyEarningsSummaryBaseRewardMigration(ctx context.Context) (bool, error) {
	conn, err := s.pool.Acquire(ctx)
	if err != nil {
		return false, err
	}
	defer conn.Release()
	var done bool
	check := func() error {
		return conn.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE id=$1)`, earningsSummaryBaseRewardMigrationID).Scan(&done)
	}
	if err := check(); err != nil {
		return false, err
	}
	if done {
		return false, nil
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		if _, err := conn.Exec(cleanup, `SELECT pg_advisory_unlock(hashtext($1))`, earningsSummaryBaseRewardLockKey); err != nil {
			// Never return a potentially lock-owning session to the shared pool.
			_ = conn.Conn().Close(cleanup)
		}
	}()
	if _, err := conn.Exec(ctx, `SELECT pg_advisory_lock(hashtext($1))`, earningsSummaryBaseRewardLockKey); err != nil {
		return false, err
	}
	if err := check(); err != nil {
		return false, err
	}
	if done {
		return false, nil
	}
	if err := planEarningsSummaryBaseRewardBackfill(ctx, conn); err != nil {
		return false, err
	}
	for {
		applied, err := applyNextEarningsSummaryBaseRewards(ctx, conn, earningsSummaryBaseRewardBatch)
		if err != nil {
			return false, err
		}
		if !applied {
			break
		}
	}
	if _, err := conn.Exec(ctx, `INSERT INTO schema_migrations(id) VALUES($1) ON CONFLICT(id) DO NOTHING`, earningsSummaryBaseRewardMigrationID); err != nil {
		return false, fmt.Errorf("store: finish earnings summary base reward migration: %w", err)
	}
	return true, nil
}

// planEarningsSummaryBaseRewardBackfill is a no-op once the plan marker exists:
// pending rows and marker commit together, so a resumed boot only drains the
// queue. Nothing is applied before the marker commits, so a failed plan is
// simply replanned from a fresh snapshot.
func planEarningsSummaryBaseRewardBackfill(ctx context.Context, db earningsSummaryMigrationDB) error {
	var ready bool
	if err := db.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE id=$1)`, earningsSummaryBaseRewardPlanID).Scan(&ready); err != nil {
		return err
	}
	if ready {
		return nil
	}
	tx, err := db.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	// BEGIN alone does not establish a snapshot; pin it before reading history.
	var snapshot string
	if err := tx.QueryRow(ctx, `SELECT pg_current_snapshot()::text`).Scan(&snapshot); err != nil {
		return fmt.Errorf("store: pin earnings base reward snapshot: %w", err)
	}
	if _, err := tx.Exec(ctx, planEarningsSummaryBaseReward); err != nil {
		return fmt.Errorf("store: plan earnings summary base reward backfill: %w", err)
	}
	tag, err := tx.Exec(ctx, `INSERT INTO schema_migrations(id) VALUES($1) ON CONFLICT(id) DO NOTHING`, earningsSummaryBaseRewardPlanID)
	if err != nil {
		return fmt.Errorf("store: claim earnings summary base reward plan: %w", err)
	}
	if tag.RowsAffected() != 1 {
		return fmt.Errorf("store: earnings base reward plan marker appeared during planning; pinned plan was not applied")
	}
	return tx.Commit(ctx)
}

// applyNextEarningsSummaryBaseRewards adds up to limit pending accounts'
// history to their live counters and dequeues them in the same statement, so
// a crash resumes without adding any account twice. A summary row is never missing for
// a settled draw in practice; if it were, it is created with the base reward
// as its total so total_micro_usd stays >= total_base_reward_micro_usd.
func applyNextEarningsSummaryBaseRewards(ctx context.Context, db earningsSummaryMigrationDB, limit int) (bool, error) {
	tag, err := db.Exec(ctx, `WITH pending AS MATERIALIZED (
  SELECT * FROM earnings_summary_base_reward_pending ORDER BY account_id LIMIT $1 FOR UPDATE
 ), applied AS (
  INSERT INTO earnings_summary(key,key_type,total_count,total_micro_usd,total_prompt_tokens,total_completion_tokens,total_base_reward_micro_usd,updated_at)
  SELECT account_id,'account',0,amount_micro_usd,0,0,amount_micro_usd,NOW() FROM pending
  ON CONFLICT(key,key_type) DO UPDATE SET
   total_base_reward_micro_usd=earnings_summary.total_base_reward_micro_usd+EXCLUDED.total_base_reward_micro_usd,
   updated_at=NOW()
  RETURNING key
 ) DELETE FROM earnings_summary_base_reward_pending p USING applied a WHERE p.account_id=a.key`, limit)
	if err != nil {
		return false, fmt.Errorf("store: apply earnings summary base reward history: %w", err)
	}
	return tag.RowsAffected() > 0, nil
}
