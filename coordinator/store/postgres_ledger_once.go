package store

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

func (s *PostgresStore) CreditOnce(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) (bool, error) {
	return s.creditOnce(accountID, amountMicroUSD, entryType, reference, false)
}

func (s *PostgresStore) CreditWithdrawableOnce(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) (bool, error) {
	return s.creditOnce(accountID, amountMicroUSD, entryType, reference, true)
}

// creditOnce serializes duplicate deliveries across store instances with a
// transaction-scoped advisory lock. The reference check, balance and ledger
// write commit together; a prior matching ledger row suppresses a replay.
func (s *PostgresStore) creditOnce(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string, withdrawable bool) (bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, fmt.Errorf("store: begin tx: %w", err)
	}
	defer tx.Rollback(ctx)

	applied, err := creditOnceTx(ctx, tx, accountID, amountMicroUSD, entryType, reference, withdrawable)
	if err != nil {
		return false, err
	}
	return applied, tx.Commit(ctx)
}

func creditWithdrawableOnceTx(ctx context.Context, tx pgx.Tx, accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) (bool, error) {
	return creditOnceTx(ctx, tx, accountID, amountMicroUSD, entryType, reference, true)
}

// creditOnceTx also serves reversal refunds in the caller's transaction.
func creditOnceTx(ctx context.Context, tx pgx.Tx, accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string, withdrawable bool) (bool, error) {
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, string(entryType)+":"+reference); err != nil {
		return false, fmt.Errorf("store: advisory lock: %w", err)
	}
	// The digest index accepts arbitrary-length ledger references. Exact
	// reference equality remains authoritative when digests share a bucket.
	var exists bool
	if err := tx.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM ledger_entries
		  WHERE account_id = $1 AND entry_type = $2
		    AND md5(reference) = md5($3) AND reference = $3)`,
		accountID, string(entryType), reference).Scan(&exists); err != nil {
		return false, fmt.Errorf("store: check ledger reference: %w", err)
	}
	if exists {
		return false, nil
	}
	credit := creditBalance
	if withdrawable {
		credit = creditWithdrawableBalance
	}
	if err := credit(ctx, tx, accountID, amountMicroUSD, entryType, reference, time.Time{}); err != nil {
		return false, err
	}
	return true, nil
}
