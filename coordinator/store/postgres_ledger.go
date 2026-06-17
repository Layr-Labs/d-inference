package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

// GetBalance returns the current balance in micro-USD for an account.
func (s *PostgresStore) GetBalance(accountID string) int64 {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var balance int64
	err := s.pool.QueryRow(ctx,
		`SELECT balance_micro_usd FROM balances WHERE account_id = $1`, accountID,
	).Scan(&balance)
	if err != nil {
		return 0
	}
	return balance
}

func nullableCreatedAt(ts time.Time) any {
	if ts.IsZero() {
		return nil
	}
	return ts
}

func creditTx(ctx context.Context, tx pgx.Tx, accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string, createdAt time.Time) error {
	_, err := tx.Exec(ctx,
		`INSERT INTO balances (account_id, balance_micro_usd, updated_at)
		 VALUES ($1, $2, NOW())
		 ON CONFLICT (account_id) DO UPDATE SET
		   balance_micro_usd = balances.balance_micro_usd + $2,
		   updated_at = NOW()`,
		accountID, amountMicroUSD,
	)
	if err != nil {
		return fmt.Errorf("store: credit balance: %w", err)
	}

	var balanceAfter int64
	err = tx.QueryRow(ctx,
		`SELECT balance_micro_usd FROM balances WHERE account_id = $1`, accountID,
	).Scan(&balanceAfter)
	if err != nil {
		return fmt.Errorf("store: read balance: %w", err)
	}

	_, err = tx.Exec(ctx,
		`INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference, created_at)
		 VALUES ($1, $2, $3, $4, $5, COALESCE($6, NOW()))`,
		accountID, string(entryType), amountMicroUSD, balanceAfter, reference, nullableCreatedAt(createdAt),
	)
	if err != nil {
		return fmt.Errorf("store: insert ledger entry: %w", err)
	}

	return nil
}

func creditWithdrawableTx(ctx context.Context, tx pgx.Tx, accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string, createdAt time.Time) error {
	_, err := tx.Exec(ctx,
		`INSERT INTO balances (account_id, balance_micro_usd, withdrawable_micro_usd, updated_at)
		 VALUES ($1, $2, $2, NOW())
		 ON CONFLICT (account_id) DO UPDATE SET
		   balance_micro_usd = balances.balance_micro_usd + $2,
		   withdrawable_micro_usd = balances.withdrawable_micro_usd + $2,
		   updated_at = NOW()`,
		accountID, amountMicroUSD,
	)
	if err != nil {
		return fmt.Errorf("store: credit withdrawable balance: %w", err)
	}

	var balanceAfter int64
	err = tx.QueryRow(ctx,
		`SELECT balance_micro_usd FROM balances WHERE account_id = $1`, accountID,
	).Scan(&balanceAfter)
	if err != nil {
		return fmt.Errorf("store: read balance: %w", err)
	}

	_, err = tx.Exec(ctx,
		`INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference, created_at)
		 VALUES ($1, $2, $3, $4, $5, COALESCE($6, NOW()))`,
		accountID, string(entryType), amountMicroUSD, balanceAfter, reference, nullableCreatedAt(createdAt),
	)
	if err != nil {
		return fmt.Errorf("store: insert ledger entry: %w", err)
	}

	return nil
}

// Credit adds micro-USD to an account and records a ledger entry (atomic).
func (s *PostgresStore) Credit(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin tx: %w", err)
	}
	defer tx.Rollback(ctx)

	if err := creditTx(ctx, tx, accountID, amountMicroUSD, entryType, reference, time.Time{}); err != nil {
		return err
	}

	return tx.Commit(ctx)
}

// GetWithdrawableBalance returns the withdrawable balance in micro-USD.
func (s *PostgresStore) GetWithdrawableBalance(accountID string) int64 {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var balance int64
	err := s.pool.QueryRow(ctx,
		`SELECT withdrawable_micro_usd FROM balances WHERE account_id = $1`, accountID,
	).Scan(&balance)
	if err != nil {
		return 0
	}
	return balance
}

// GetBalanceWithWithdrawable returns both balances in a single query.
func (s *PostgresStore) GetBalanceWithWithdrawable(accountID string) (int64, int64) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var balance, withdrawable int64
	err := s.pool.QueryRow(ctx,
		`SELECT balance_micro_usd, withdrawable_micro_usd FROM balances WHERE account_id = $1`, accountID,
	).Scan(&balance, &withdrawable)
	if err != nil {
		return 0, 0
	}
	return balance, withdrawable
}

// CreditWithdrawable adds micro-USD to both the total balance and the
// withdrawable balance, and records a ledger entry.
func (s *PostgresStore) CreditWithdrawable(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin tx: %w", err)
	}
	defer tx.Rollback(ctx)

	if err := creditWithdrawableTx(ctx, tx, accountID, amountMicroUSD, entryType, reference, time.Time{}); err != nil {
		return err
	}

	return tx.Commit(ctx)
}

// Debit subtracts micro-USD from an account. Returns error if insufficient funds.
func (s *PostgresStore) Debit(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Single-statement CTE: debit balance, cap withdrawable, insert ledger
	// entry -- all in one round trip. The old implementation used 5 sequential
	// round trips (BEGIN + 2 UPDATEs + INSERT + COMMIT) which paid full
	// network latency to Postgres on each hop (~200ms × 5 = 1s+).
	var balanceAfter int64
	err := s.pool.QueryRow(ctx, `
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

// MigrateAccountBalance moves the full balance (and withdrawable subset) from
// one account ID to another in a single transaction. No-op (false) when the
// source has no balance row or a zero balance.
func (s *PostgresStore) MigrateAccountBalance(from, to string) (bool, error) {
	if from == "" || to == "" || from == to {
		return false, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, fmt.Errorf("store: begin migrate tx: %w", err)
	}
	defer tx.Rollback(ctx)

	var bal, wdr int64
	err = tx.QueryRow(ctx,
		`SELECT balance_micro_usd, withdrawable_micro_usd FROM balances WHERE account_id = $1 FOR UPDATE`, from,
	).Scan(&bal, &wdr)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("store: read source balance: %w", err)
	}
	if bal == 0 && wdr == 0 {
		return false, nil
	}

	// Zero the source and record the outgoing leg.
	if _, err := tx.Exec(ctx,
		`UPDATE balances SET balance_micro_usd = 0, withdrawable_micro_usd = 0, updated_at = NOW() WHERE account_id = $1`, from,
	); err != nil {
		return false, fmt.Errorf("store: zero source balance: %w", err)
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
		 VALUES ($1, $2, $3, 0, 'migrate:out')`,
		from, string(LedgerMigration), -bal,
	); err != nil {
		return false, fmt.Errorf("store: source migration ledger entry: %w", err)
	}

	// Credit the destination and record the incoming leg.
	var destBalance int64
	if err := tx.QueryRow(ctx,
		`INSERT INTO balances (account_id, balance_micro_usd, withdrawable_micro_usd, updated_at)
		 VALUES ($1, $2, $3, NOW())
		 ON CONFLICT (account_id) DO UPDATE SET
		   balance_micro_usd = balances.balance_micro_usd + $2,
		   withdrawable_micro_usd = balances.withdrawable_micro_usd + $3,
		   updated_at = NOW()
		 RETURNING balance_micro_usd`,
		to, bal, wdr,
	).Scan(&destBalance); err != nil {
		return false, fmt.Errorf("store: credit destination balance: %w", err)
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
		 VALUES ($1, $2, $3, $4, 'migrate:in')`,
		to, string(LedgerMigration), bal, destBalance,
	); err != nil {
		return false, fmt.Errorf("store: destination migration ledger entry: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return false, fmt.Errorf("store: commit migrate: %w", err)
	}
	return true, nil
}

// DebitWithdrawable subtracts micro-USD from both the total balance and the
// withdrawable balance atomically. Returns error if the withdrawable balance
// is insufficient. This ensures withdrawal debits are symmetric with
// CreditWithdrawable refunds — both touch the same columns.
func (s *PostgresStore) DebitWithdrawable(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin tx: %w", err)
	}
	defer tx.Rollback(ctx)

	var balanceAfter int64
	err = tx.QueryRow(ctx,
		`UPDATE balances
		 SET balance_micro_usd = balance_micro_usd - $2,
		     withdrawable_micro_usd = withdrawable_micro_usd - $2,
		     updated_at = NOW()
		 WHERE account_id = $1
		   AND balance_micro_usd >= $2
		   AND withdrawable_micro_usd >= $2
		 RETURNING balance_micro_usd`,
		accountID, amountMicroUSD,
	).Scan(&balanceAfter)
	if err != nil {
		return errors.New("insufficient withdrawable balance or account not found")
	}

	_, err = tx.Exec(ctx,
		`INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
		 VALUES ($1, $2, $3, $4, $5)`,
		accountID, string(entryType), -amountMicroUSD, balanceAfter, reference,
	)
	if err != nil {
		return fmt.Errorf("store: insert ledger entry: %w", err)
	}

	return tx.Commit(ctx)
}

// LedgerHistory returns ledger entries for an account, newest first.
func (s *PostgresStore) LedgerHistory(accountID string) []LedgerEntry {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Cap at 500 most-recent entries. Older history isn't shown on any
	// dashboard and was responsible for sending tens of thousands of rows
	// per request to high-volume accounts.
	rows, err := s.pool.Query(ctx,
		`SELECT id, account_id, entry_type, amount_micro_usd, balance_after, reference, created_at
		 FROM ledger_entries WHERE account_id = $1 ORDER BY created_at DESC LIMIT 500`,
		accountID,
	)
	if err != nil {
		return []LedgerEntry{}
	}
	defer rows.Close()

	var entries []LedgerEntry
	for rows.Next() {
		var e LedgerEntry
		var entryType string
		if err := rows.Scan(&e.ID, &e.AccountID, &entryType, &e.AmountMicroUSD, &e.BalanceAfter, &e.Reference, &e.CreatedAt); err != nil {
			continue
		}
		e.Type = LedgerEntryType(entryType)
		entries = append(entries, e)
	}
	if entries == nil {
		return []LedgerEntry{}
	}
	return entries
}

// KeyCount returns the number of active API keys.
func (s *PostgresStore) KeyCount() int {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var count int
	err := s.pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM api_keys WHERE active = TRUE`,
	).Scan(&count)
	if err != nil {
		return 0
	}
	return count
}
