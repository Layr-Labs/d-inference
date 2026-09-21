package store

import (
	"context"
	"errors"
	"fmt"
	"github.com/jackc/pgx/v5"
)

func debitBalance(ctx context.Context, q pgQuerier, accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error {

	// Single-statement CTE: debit balance, cap withdrawable, insert ledger
	// entry -- all in one round trip. The old implementation used 5 sequential
	// round trips (BEGIN + 2 UPDATEs + INSERT + COMMIT) which paid full
	// network latency to Postgres on each hop (~200ms × 5 = 1s+).
	var balanceAfter int64
	err := q.QueryRow(ctx, `
		WITH debit AS (
			UPDATE balances
			SET balance_micro_usd = balance_micro_usd - $2,
			    withdrawable_micro_usd = LEAST(withdrawable_micro_usd, balance_micro_usd - $2),
			    updated_at = NOW()
			WHERE account_id = $1 AND balance_micro_usd >= $2
			RETURNING balance_micro_usd
		), ledger AS (
			INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
			SELECT $1, $3, -$2, balance_micro_usd, $4
			FROM debit
		)
		SELECT balance_micro_usd FROM debit`,
		accountID, amountMicroUSD, string(entryType), reference,
	).Scan(&balanceAfter)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrInsufficientBalance
		}
		return fmt.Errorf("debit: %w", err)
	}
	return nil
}
