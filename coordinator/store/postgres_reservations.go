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
			return 0, false, fmt.Errorf("store: commit reservation replay: %v: %w", err, ErrCommitOutcomeUnknown)
		}
		return existing.withdrawableMicroUSD, false, nil
	}

	var balance, withdrawable int64
	err = tx.QueryRow(ctx,
		`SELECT balance_micro_usd, withdrawable_micro_usd
		 FROM balances WHERE account_id = $1 FOR UPDATE`,
		accountID,
	).Scan(&balance, &withdrawable)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, false, ErrInsufficientBalance
	}
	if err != nil {
		return 0, false, fmt.Errorf("store: lock inference balance: %w", err)
	}
	if balance < amountMicroUSD {
		return 0, false, ErrInsufficientBalance
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
		return 0, false, fmt.Errorf("store: commit inference reservation: %v: %w", err, ErrCommitOutcomeUnknown)
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
			return false, fmt.Errorf("store: commit release replay: %v: %w", err, ErrCommitOutcomeUnknown)
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
		return false, fmt.Errorf("store: commit reservation release: %v: %w", err, ErrCommitOutcomeUnknown)
	}
	return true, nil
}

func (s *PostgresStore) RecoverStaleInferenceReservations(before time.Time) (int, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return 0, fmt.Errorf("store: begin stale reservation recovery: %w", err)
	}
	defer tx.Rollback(ctx)
	rows, err := tx.Query(ctx,
		`SELECT operation_key, account_id, amount_micro_usd, withdrawable_micro_usd
		 FROM balance_reservation_operations AS reserve
		 WHERE reserve.kind = 'reserve'
		   AND reserve.operation_key NOT LIKE 'topup:%'
		   AND reserve.created_at < $1
		   AND NOT EXISTS (
		       SELECT 1 FROM balance_reservation_operations AS final
		       WHERE final.operation_key = 'finalize:' || reserve.operation_key
		   )
		   AND NOT EXISTS (
		       SELECT 1 FROM inference_settlements
		       WHERE reservation_id = reserve.operation_key
		   )
		   AND NOT EXISTS (
		       SELECT 1 FROM inference_settlement_reviews
		       WHERE reservation_id = reserve.operation_key
		   )
		 ORDER BY reserve.created_at
		 LIMIT 100`,
		before,
	)
	if err != nil {
		return 0, fmt.Errorf("store: find stale reservations: %w", err)
	}
	type staleReservation struct {
		operationKey, accountID              string
		amountMicroUSD, withdrawableMicroUSD int64
	}
	var stale []staleReservation
	for rows.Next() {
		var reservation staleReservation
		if err := rows.Scan(
			&reservation.operationKey, &reservation.accountID,
			&reservation.amountMicroUSD, &reservation.withdrawableMicroUSD,
		); err != nil {
			rows.Close()
			return 0, fmt.Errorf("store: scan stale reservation: %w", err)
		}
		stale = append(stale, reservation)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return 0, fmt.Errorf("store: iterate stale reservations: %w", err)
	}
	rows.Close()

	released := 0
	for _, reservation := range stale {
		finalizationKey := "finalize:" + reservation.operationKey
		if err := lockFinancialOperation(ctx, tx, finalizationKey); err != nil {
			return 0, err
		}
		if _, found, err := reservationOperationTx(ctx, tx, finalizationKey); err != nil {
			return 0, err
		} else if found {
			continue
		}
		var reviewPending bool
		if err := tx.QueryRow(ctx,
			`SELECT EXISTS (
				SELECT 1 FROM inference_settlement_reviews WHERE reservation_id = $1
			)`,
			reservation.operationKey,
		).Scan(&reviewPending); err != nil {
			return 0, fmt.Errorf("store: recheck settlement review: %w", err)
		}
		if reviewPending {
			continue
		}
		topups, err := staleReservationTopUps(ctx, tx, reservation.operationKey)
		if err != nil {
			return 0, err
		}
		total := reservation.amountMicroUSD
		totalWithdrawable := reservation.withdrawableMicroUSD
		for _, topup := range topups {
			total += topup.amountMicroUSD
			totalWithdrawable += topup.withdrawableMicroUSD
		}
		if err := creditBalanceTx(
			ctx, tx, reservation.accountID, total, totalWithdrawable,
			LedgerRefund, "stale_reservation_recovery:"+reservation.operationKey,
		); err != nil {
			return 0, err
		}
		if err := insertReservationOperationTx(ctx, tx, finalizationKey, persistedReservationOperation{
			accountID: reservation.accountID, kind: "release",
			amountMicroUSD: total, withdrawableMicroUSD: totalWithdrawable,
		}); err != nil {
			return 0, err
		}
		for _, topup := range topups {
			releaseKey := "topup-release:" + topup.operationKey[len("topup:"):]
			if err := insertReservationOperationTx(ctx, tx, releaseKey, persistedReservationOperation{
				accountID: reservation.accountID, kind: "release",
				amountMicroUSD:       topup.amountMicroUSD,
				withdrawableMicroUSD: topup.withdrawableMicroUSD,
			}); err != nil {
				return 0, err
			}
		}
		released++
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, fmt.Errorf("store: commit stale reservation recovery: %v: %w", err, ErrCommitOutcomeUnknown)
	}
	return released, nil
}

func staleReservationTopUps(
	ctx context.Context,
	tx pgx.Tx,
	reservationID string,
) ([]persistedReservationOperationWithKey, error) {
	rows, err := tx.Query(ctx,
		`SELECT operation_key, account_id, kind, amount_micro_usd, withdrawable_micro_usd
		 FROM balance_reservation_operations AS topup
		 WHERE topup.kind = 'reserve'
		   AND topup.operation_key LIKE 'topup:' || $1 || ':%'
		   AND NOT EXISTS (
		       SELECT 1 FROM balance_reservation_operations AS released
		       WHERE released.operation_key =
		             'topup-release:' || substring(topup.operation_key FROM 7)
		   )
		 ORDER BY topup.operation_key
		 FOR UPDATE`,
		reservationID,
	)
	if err != nil {
		return nil, fmt.Errorf("store: find stale reservation top-ups: %w", err)
	}
	defer rows.Close()
	var operations []persistedReservationOperationWithKey
	for rows.Next() {
		var operation persistedReservationOperationWithKey
		if err := rows.Scan(
			&operation.operationKey, &operation.accountID, &operation.kind,
			&operation.amountMicroUSD, &operation.withdrawableMicroUSD,
		); err != nil {
			return nil, fmt.Errorf("store: scan stale reservation top-up: %w", err)
		}
		operations = append(operations, operation)
	}
	return operations, rows.Err()
}

type persistedReservationOperationWithKey struct {
	operationKey string
	persistedReservationOperation
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
