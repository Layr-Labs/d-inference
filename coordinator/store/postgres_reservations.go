package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

type persistedReservationOperation struct {
	accountID            string
	kind                 string
	amountMicroUSD       int64
	withdrawableMicroUSD int64
}

func (s *PostgresStore) ReserveInferenceBalance(accountID string, amountMicroUSD int64, operationKey string) (int64, bool, error) {
	if amountMicroUSD <= 0 || operationKey == "" {
		return 0, false, ErrFinancialOperationConflict
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return 0, false, fmt.Errorf("store: begin inference reservation: %w", err)
	}
	defer tx.Rollback(ctx)
	if err := lockFinancialOperation(ctx, tx, operationKey); err != nil {
		return 0, false, err
	}
	existing, found, err := reservationOperationTx(ctx, tx, operationKey)
	if err != nil {
		return 0, false, err
	}
	if found {
		if existing.accountID != accountID || existing.kind != "reserve" ||
			existing.amountMicroUSD != amountMicroUSD {
			return 0, false, ErrFinancialOperationConflict
		}
		if err := tx.Commit(ctx); err != nil {
			return 0, false, fmt.Errorf("store: commit reservation replay: %w", err)
		}
		return existing.withdrawableMicroUSD, false, nil
	}

	var balance, withdrawable int64
	err = tx.QueryRow(ctx,
		`SELECT balance_micro_usd, withdrawable_micro_usd
		 FROM balances WHERE account_id = $1 FOR UPDATE`,
		accountID,
	).Scan(&balance, &withdrawable)
	if errors.Is(err, pgx.ErrNoRows) || balance < amountMicroUSD {
		return 0, false, ErrInsufficientBalance
	}
	if err != nil {
		return 0, false, fmt.Errorf("store: lock inference balance: %w", err)
	}
	reservedWithdrawable := max(int64(0), amountMicroUSD-(balance-withdrawable))
	if reservedWithdrawable > withdrawable {
		reservedWithdrawable = withdrawable
	}
	balanceAfter := balance - amountMicroUSD
	if _, err := tx.Exec(ctx,
		`UPDATE balances
		 SET balance_micro_usd = $2,
		     withdrawable_micro_usd = withdrawable_micro_usd - $3,
		     updated_at = NOW()
		 WHERE account_id = $1`,
		accountID, balanceAfter, reservedWithdrawable,
	); err != nil {
		return 0, false, fmt.Errorf("store: debit inference reservation: %w", err)
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO ledger_entries
			(account_id, entry_type, amount_micro_usd, balance_after, reference)
		 VALUES ($1, $2, $3, $4, $5)`,
		accountID, string(LedgerCharge), -amountMicroUSD, balanceAfter, "reserve:"+operationKey,
	); err != nil {
		return 0, false, fmt.Errorf("store: record inference reservation: %w", err)
	}
	if err := insertReservationOperationTx(ctx, tx, operationKey, persistedReservationOperation{
		accountID: accountID, kind: "reserve", amountMicroUSD: amountMicroUSD,
		withdrawableMicroUSD: reservedWithdrawable,
	}); err != nil {
		return 0, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, false, fmt.Errorf("store: commit inference reservation: %w", err)
	}
	return reservedWithdrawable, true, nil
}

func (s *PostgresStore) ReleaseInferenceReservation(accountID string, amountMicroUSD, withdrawableMicroUSD int64, operationKey, reference string) (bool, error) {
	if amountMicroUSD < 0 || withdrawableMicroUSD < 0 || withdrawableMicroUSD > amountMicroUSD || operationKey == "" {
		return false, ErrFinancialOperationConflict
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, fmt.Errorf("store: begin reservation release: %w", err)
	}
	defer tx.Rollback(ctx)
	if err := lockFinancialOperation(ctx, tx, operationKey); err != nil {
		return false, err
	}
	existing, found, err := reservationOperationTx(ctx, tx, operationKey)
	if err != nil {
		return false, err
	}
	if found {
		if existing.accountID != accountID || existing.kind != "release" ||
			existing.amountMicroUSD != amountMicroUSD ||
			existing.withdrawableMicroUSD != withdrawableMicroUSD {
			return false, ErrFinancialOperationConflict
		}
		if err := tx.Commit(ctx); err != nil {
			return false, fmt.Errorf("store: commit release replay: %w", err)
		}
		return false, nil
	}

	if amountMicroUSD > 0 {
		var balanceAfter int64
		err := tx.QueryRow(ctx,
			`INSERT INTO balances
				(account_id, balance_micro_usd, withdrawable_micro_usd, updated_at)
			 VALUES ($1, $2, $3, NOW())
			 ON CONFLICT (account_id) DO UPDATE SET
				balance_micro_usd = balances.balance_micro_usd + $2,
				withdrawable_micro_usd = balances.withdrawable_micro_usd + $3,
				updated_at = NOW()
			 RETURNING balance_micro_usd`,
			accountID, amountMicroUSD, withdrawableMicroUSD,
		).Scan(&balanceAfter)
		if err != nil {
			return false, fmt.Errorf("store: restore inference reservation: %w", err)
		}
		if _, err := tx.Exec(ctx,
			`INSERT INTO ledger_entries
				(account_id, entry_type, amount_micro_usd, balance_after, reference)
			 VALUES ($1, $2, $3, $4, $5)`,
			accountID, string(LedgerRefund), amountMicroUSD, balanceAfter, reference,
		); err != nil {
			return false, fmt.Errorf("store: record reservation release: %w", err)
		}
	}
	if err := insertReservationOperationTx(ctx, tx, operationKey, persistedReservationOperation{
		accountID: accountID, kind: "release", amountMicroUSD: amountMicroUSD,
		withdrawableMicroUSD: withdrawableMicroUSD,
	}); err != nil {
		return false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return false, fmt.Errorf("store: commit reservation release: %w", err)
	}
	return true, nil
}

func lockFinancialOperation(ctx context.Context, tx pgx.Tx, operationKey string) error {
	if _, err := tx.Exec(ctx,
		`SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`,
		operationKey,
	); err != nil {
		return fmt.Errorf("store: lock financial operation: %w", err)
	}
	return nil
}

func reservationOperationTx(ctx context.Context, tx pgx.Tx, operationKey string) (persistedReservationOperation, bool, error) {
	var operation persistedReservationOperation
	err := tx.QueryRow(ctx,
		`SELECT account_id, kind, amount_micro_usd, withdrawable_micro_usd
		 FROM balance_reservation_operations
		 WHERE operation_key = $1`,
		operationKey,
	).Scan(&operation.accountID, &operation.kind, &operation.amountMicroUSD, &operation.withdrawableMicroUSD)
	if errors.Is(err, pgx.ErrNoRows) {
		return persistedReservationOperation{}, false, nil
	}
	if err != nil {
		return persistedReservationOperation{}, false, fmt.Errorf("store: read financial operation: %w", err)
	}
	return operation, true, nil
}

func insertReservationOperationTx(
	ctx context.Context,
	tx pgx.Tx,
	operationKey string,
	operation persistedReservationOperation,
) error {
	if _, err := tx.Exec(ctx,
		`INSERT INTO balance_reservation_operations
			(operation_key, account_id, kind, amount_micro_usd, withdrawable_micro_usd)
		 VALUES ($1, $2, $3, $4, $5)`,
		operationKey, operation.accountID, operation.kind,
		operation.amountMicroUSD, operation.withdrawableMicroUSD,
	); err != nil {
		return fmt.Errorf("store: insert financial operation: %w", err)
	}
	return nil
}
