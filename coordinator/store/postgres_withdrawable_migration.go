package store

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
)

const withdrawableBalanceMigrationID = "backfill_withdrawable_balance_v1"

const legacyWithdrawableBalanceBackfill = `
	WITH classified_ledger AS MATERIALIZED (
		SELECT
			account_id,
			id,
			balance_after::numeric AS balance_after,
			CASE
				WHEN entry_type IN (
					'payout',
					'referral_reward',
					'admin_reward',
					'provider_floor_draw',
					'stripe_payout',
					'withdrawal'
				) THEN amount_micro_usd::numeric
				WHEN entry_type IN ('charge', 'refund')
				  AND strpos(reference, 'stripe_withdraw:') = 1
					THEN amount_micro_usd::numeric
				ELSE 0::numeric
			END AS withdrawable_delta,
			entry_type = 'refund'
			  AND strpos(reference, 'stripe_withdraw:') <> 1
				AS has_generic_refund,
			entry_type = 'migration' AS has_balance_migration
		FROM ledger_entries
	),
	ledger_state AS MATERIALIZED (
		SELECT
			account_id,
			id,
			balance_after,
			withdrawable_delta,
			has_generic_refund,
			has_balance_migration,
			SUM(withdrawable_delta) OVER (
				PARTITION BY account_id
				ORDER BY id
				ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
			) AS cumulative_withdrawable_delta
		FROM classified_ledger
	),
	ledger_summary AS (
		SELECT
			account_id,
			SUM(withdrawable_delta) AS final_withdrawable_delta,
			BOOL_OR(withdrawable_delta <> 0) AS has_withdrawable_activity,
			BOOL_OR(has_generic_refund) AS has_generic_refund,
			BOOL_OR(has_balance_migration) AS has_balance_migration,
			LEAST(
				0::numeric,
				MIN(balance_after - cumulative_withdrawable_delta)
			) AS ordinary_debit_adjustment
		FROM ledger_state
		GROUP BY account_id
	),
	backfill AS (
		SELECT
			b.account_id,
			GREATEST(
				0::numeric,
				LEAST(
					b.balance_micro_usd::numeric,
					s.final_withdrawable_delta + s.ordinary_debit_adjustment
				)
			)::bigint AS withdrawable_micro_usd
		FROM balances b
		JOIN ledger_summary s ON s.account_id = b.account_id
		WHERE b.balance_micro_usd > 0
		  AND NOT s.has_balance_migration
		  AND NOT (
			s.has_generic_refund
			AND s.has_withdrawable_activity
		  )
	),
	updated AS (
		UPDATE balances b
		SET withdrawable_micro_usd = backfill.withdrawable_micro_usd
		FROM backfill
		WHERE b.account_id = backfill.account_id
		  AND b.withdrawable_micro_usd = 0
		  AND backfill.withdrawable_micro_usd > 0
		RETURNING 1
	)
	SELECT
		(
			SELECT COUNT(*)
			FROM ledger_summary
			WHERE has_balance_migration
			   OR (
				has_generic_refund
				AND has_withdrawable_activity
			   )
		) AS ambiguous_accounts,
		(SELECT COUNT(*) FROM updated) AS updated_accounts`

type withdrawableMigrationResult string

const (
	withdrawableMigrationBackfilled withdrawableMigrationResult = "backfilled_legacy_schema"
	withdrawableMigrationPreserved  withdrawableMigrationResult = "preserved_existing_schema"
	withdrawableMigrationSkipped    withdrawableMigrationResult = "already_applied"
)

type withdrawableMigrationOutcome struct {
	Result       withdrawableMigrationResult
	RowsAffected int64
}

// migrateWithdrawableBalance records privacy-safe startup observability around
// the one-time financial migration. Account identifiers and monetary values are
// deliberately excluded.
func (s *PostgresStore) migrateWithdrawableBalance(ctx context.Context) error {
	started := time.Now()
	outcome, err := s.applyWithdrawableBalanceMigration(ctx)
	if err != nil {
		slog.Error("postgres migration failed",
			"migration", withdrawableBalanceMigrationID,
			"result", "failed",
			"duration_ms", time.Since(started).Milliseconds())
		return fmt.Errorf("store: migrate withdrawable balance: %w", err)
	}
	slog.Info("postgres migration completed",
		"migration", withdrawableBalanceMigrationID,
		"result", string(outcome.Result),
		"duration_ms", time.Since(started).Milliseconds())
	return nil
}

// applyWithdrawableBalanceMigration atomically claims and applies the legacy
// backfill. The unique marker insert is the concurrency gate: a concurrent
// insert waits for the claiming transaction. It then either observes the
// committed marker and skips, or acquires the claim after a rollback and
// retries the complete migration.
//
// The schema predicate is the safety boundary. A pre-existing
// withdrawable_micro_usd column proves that live split-balance accounting may
// already have started. In that state, zero is a legitimate result of charges,
// withdrawals, refunds, or account migration, and ledger history cannot
// reconstruct it safely because:
//   - generic refunds may be withdrawable Stripe reversals or non-withdrawable
//     inference reservation refunds;
//   - migration ledger entries record total balance, not the moved withdrawable
//     subset; and
//   - ordinary charges consume non-withdrawable credit before earnings.
//
// Therefore an existing column is preserved byte-for-byte and only receives
// the marker. The set-wise historical reconstruction runs solely when this
// transaction itself adds the column to a legacy schema. That is the only
// authoritative boundary available: the original deployment stored no marker
// or cutoff. The reconstruction replays financial provenance set-wise in
// ledger ID order. Direct withdrawable deltas are provider/referral/admin/floor
// earnings, explicit withdrawal types, and pre-split Stripe charge/refund rows
// identified by their stripe_withdraw: reference. Ordinary charges clamp
// withdrawable funds only after non-withdrawable credit is exhausted, and later
// deposits never reclassify spent earnings. A generic refund cannot reveal how
// much of its original debit consumed each provenance class, and
// LedgerMigration records total balance rather than the separately moved
// withdrawable subset. A legacy schema containing either ambiguity fails
// closed, rolling back the marker and column for explicit offline
// reconciliation instead of guessing.
func (s *PostgresStore) applyWithdrawableBalanceMigration(ctx context.Context) (withdrawableMigrationOutcome, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return withdrawableMigrationOutcome{}, fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback(ctx)

	var claimed bool
	err = tx.QueryRow(ctx, `
		INSERT INTO schema_migrations (id)
		VALUES ($1)
		ON CONFLICT (id) DO NOTHING
		RETURNING true`,
		withdrawableBalanceMigrationID,
	).Scan(&claimed)
	if errors.Is(err, pgx.ErrNoRows) {
		return withdrawableMigrationOutcome{Result: withdrawableMigrationSkipped}, nil
	}
	if err != nil {
		return withdrawableMigrationOutcome{}, fmt.Errorf("claim marker: %w", err)
	}
	if !claimed {
		return withdrawableMigrationOutcome{}, errors.New("marker claim returned false")
	}

	var columnExists bool
	if err := tx.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1
			FROM information_schema.columns
			WHERE table_schema = current_schema()
			  AND table_name = 'balances'
			  AND column_name = 'withdrawable_micro_usd'
		)`).Scan(&columnExists); err != nil {
		return withdrawableMigrationOutcome{}, fmt.Errorf("inspect balances schema: %w", err)
	}

	if columnExists {
		if err := tx.Commit(ctx); err != nil {
			return withdrawableMigrationOutcome{}, fmt.Errorf("commit preserved marker: %w", err)
		}
		return withdrawableMigrationOutcome{Result: withdrawableMigrationPreserved}, nil
	}

	if _, err := tx.Exec(ctx,
		`ALTER TABLE balances ADD COLUMN IF NOT EXISTS withdrawable_micro_usd BIGINT NOT NULL DEFAULT 0`,
	); err != nil {
		return withdrawableMigrationOutcome{}, fmt.Errorf("add withdrawable column: %w", err)
	}

	var ambiguousAccounts, updatedAccounts int64
	if err := tx.QueryRow(ctx, legacyWithdrawableBalanceBackfill).Scan(
		&ambiguousAccounts,
		&updatedAccounts,
	); err != nil {
		return withdrawableMigrationOutcome{}, fmt.Errorf("backfill legacy balances: %w", err)
	}
	if ambiguousAccounts > 0 {
		return withdrawableMigrationOutcome{}, fmt.Errorf(
			"legacy ledger provenance is ambiguous for %d accounts; offline reconciliation required",
			ambiguousAccounts,
		)
	}
	if err := tx.Commit(ctx); err != nil {
		return withdrawableMigrationOutcome{}, fmt.Errorf("commit: %w", err)
	}
	return withdrawableMigrationOutcome{
		Result:       withdrawableMigrationBackfilled,
		RowsAffected: updatedAccounts,
	}, nil
}
