package postgres

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
)

// rewardLedgerTypesSQLList renders RewardLedgerTypes as a comma-separated list
// of single-quoted SQL string literals (e.g. "'referral_reward','admin_reward'")
// for use in an IN (...) clause. The values are package constants, never user
// input, so literal interpolation here is safe from SQL injection.
func rewardLedgerTypesSQLList() string {
	out := ""
	for i, t := range store.RewardLedgerTypes {
		if i > 0 {
			out += ","
		}
		out += "'" + string(t) + "'"
	}
	return out
}

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

// pgQuerier is the subset of *pgxpool.Pool and pgx.Tx the single-statement
// ledger helpers need, so one helper serves both a standalone call (pool: one
// round trip in an implicit transaction) and a caller's open transaction.
type pgQuerier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// creditBalanceSQL credits an account and records its ledger row in ONE
// data-modifying CTE — one round trip instead of BEGIN + upsert + SELECT +
// INSERT + COMMIT. The upsert's RETURNING is the post-credit balance, so
// balance_after is exactly the value the old in-transaction SELECT read; the
// ledger INSERT runs exactly once, to completion, under the row lock the
// upsert took, so concurrent credits/debits on the account still serialize
// on that one lock and no update is lost. Unknown accounts are created and
// zero or negative amounts are applied and recorded, exactly as before.
const creditBalanceSQL = `
		WITH credit AS (
			INSERT INTO balances (account_id, balance_micro_usd, updated_at)
			VALUES ($1, $2, NOW())
			ON CONFLICT (account_id) DO UPDATE SET
			  balance_micro_usd = balances.balance_micro_usd + $2,
			  updated_at = NOW()
			RETURNING balance_micro_usd
		), ledger AS (
			INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference, created_at)
			SELECT $1, $3, $2, balance_micro_usd, $4, COALESCE($5::timestamptz, NOW())
			FROM credit
		)
		SELECT balance_micro_usd FROM credit`

// creditWithdrawableBalanceSQL is creditBalanceSQL that also raises the
// withdrawable subset by the same amount.
const creditWithdrawableBalanceSQL = `
		WITH credit AS (
			INSERT INTO balances (account_id, balance_micro_usd, withdrawable_micro_usd, updated_at)
			VALUES ($1, $2, $2, NOW())
			ON CONFLICT (account_id) DO UPDATE SET
			  balance_micro_usd = balances.balance_micro_usd + $2,
			  withdrawable_micro_usd = balances.withdrawable_micro_usd + $2,
			  updated_at = NOW()
			RETURNING balance_micro_usd
		), ledger AS (
			INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference, created_at)
			SELECT $1, $3, $2, balance_micro_usd, $4, COALESCE($5::timestamptz, NOW())
			FROM credit
		)
		SELECT balance_micro_usd FROM credit`

// creditBalance applies creditBalanceSQL through q (the pool for a standalone
// credit, or the caller's transaction). A zero createdAt records NOW().
func creditBalance(ctx context.Context, q pgQuerier, accountID string, amountMicroUSD int64, entryType store.LedgerEntryType, reference string, createdAt time.Time) error {
	var balanceAfter int64
	if err := q.QueryRow(ctx, creditBalanceSQL,
		accountID, amountMicroUSD, string(entryType), reference, nullableCreatedAt(createdAt),
	).Scan(&balanceAfter); err != nil {
		return fmt.Errorf("store: credit balance: %w", err)
	}
	return nil
}

// creditWithdrawableBalance applies creditWithdrawableBalanceSQL through q.
func creditWithdrawableBalance(ctx context.Context, q pgQuerier, accountID string, amountMicroUSD int64, entryType store.LedgerEntryType, reference string, createdAt time.Time) error {
	var balanceAfter int64
	if err := q.QueryRow(ctx, creditWithdrawableBalanceSQL,
		accountID, amountMicroUSD, string(entryType), reference, nullableCreatedAt(createdAt),
	).Scan(&balanceAfter); err != nil {
		return fmt.Errorf("store: credit withdrawable balance: %w", err)
	}
	return nil
}

// Credit adds micro-USD to an account and records a ledger entry (atomic).
func (s *PostgresStore) Credit(accountID string, amountMicroUSD int64, entryType store.LedgerEntryType, reference string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// One statement, one round trip: the balance upsert and its ledger row
	// still commit together or not at all (creditBalanceSQL).
	return creditBalance(ctx, s.pool, accountID, amountMicroUSD, entryType, reference, time.Time{})
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
func (s *PostgresStore) CreditWithdrawable(accountID string, amountMicroUSD int64, entryType store.LedgerEntryType, reference string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// One statement, one round trip (creditWithdrawableBalanceSQL).
	return creditWithdrawableBalance(ctx, s.pool, accountID, amountMicroUSD, entryType, reference, time.Time{})
}

// CreditWithdrawableOnce credits only if no ledger entry with the same
// (entryType, reference) exists yet. A transaction-scoped advisory lock on
// the reference serializes concurrent deliveries of the same webhook so the
// existence check can't race its own insert.
func (s *PostgresStore) CreditWithdrawableOnce(accountID string, amountMicroUSD int64, entryType store.LedgerEntryType, reference string) (bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, fmt.Errorf("store: begin tx: %w", err)
	}
	defer tx.Rollback(ctx)

	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, string(entryType)+":"+reference); err != nil {
		return false, fmt.Errorf("store: advisory lock: %w", err)
	}
	// Scoped by account so the existence check rides the existing
	// idx_ledger_account index instead of needing a new (large-table,
	// boot-time) index migration. Refund references embed the withdrawal
	// UUID, so (account, type, reference) is exactly as unique.
	var exists bool
	if err := tx.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM ledger_entries
		  WHERE account_id = $1 AND entry_type = $2 AND reference = $3)`,
		accountID, string(entryType), reference).Scan(&exists); err != nil {
		return false, fmt.Errorf("store: check ledger reference: %w", err)
	}
	if exists {
		return false, tx.Commit(ctx)
	}
	if err := creditWithdrawableBalance(ctx, tx, accountID, amountMicroUSD, entryType, reference, time.Time{}); err != nil {
		return false, err
	}
	return true, tx.Commit(ctx)
}

// Debit subtracts micro-USD from an account. Returns error if insufficient funds.
func (s *PostgresStore) Debit(accountID string, amountMicroUSD int64, entryType store.LedgerEntryType, reference string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	return debitBalance(ctx, s.pool, accountID, amountMicroUSD, entryType, reference)
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
		from, string(store.LedgerMigration), -bal,
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
		to, string(store.LedgerMigration), bal, destBalance,
	); err != nil {
		return false, fmt.Errorf("store: destination migration ledger entry: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return false, fmt.Errorf("store: commit migrate: %w", err)
	}
	return true, nil
}

// LedgerHistory returns ledger entries for an account, newest first.
func (s *PostgresStore) LedgerHistory(accountID string) []store.LedgerEntry {
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
		return []store.LedgerEntry{}
	}
	defer rows.Close()

	var entries []store.LedgerEntry
	for rows.Next() {
		var e store.LedgerEntry
		var entryType string
		if err := rows.Scan(&e.ID, &e.AccountID, &entryType, &e.AmountMicroUSD, &e.BalanceAfter, &e.Reference, &e.CreatedAt); err != nil {
			continue
		}
		e.Type = store.LedgerEntryType(entryType)
		entries = append(entries, e)
	}
	if entries == nil {
		return []store.LedgerEntry{}
	}
	return entries
}
