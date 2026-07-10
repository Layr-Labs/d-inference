package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

func (s *PostgresStore) ReserveInferenceBalance(accountID string, amountMicroUSD int64, operationKey string) (int64, bool, error) {
	if amountMicroUSD <= 0 || operationKey == "" {
		return 0, false, ErrFinancialOperationConflict
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	claimToken := uuid.NewString()
	var reservedWithdrawable int64
	var disposition string
	err := s.pool.QueryRow(ctx, `
		WITH claim AS (
			INSERT INTO balance_reservation_operations
				(operation_key, account_id, kind, amount_micro_usd, withdrawable_micro_usd, claim_token)
			VALUES ($3, $1, 'reserve', $2, 0, $5)
			ON CONFLICT (operation_key) DO UPDATE
				SET operation_key = EXCLUDED.operation_key
			RETURNING account_id, kind, amount_micro_usd, withdrawable_micro_usd,
			          claim_token = $5 AS owns_claim
		), current AS MATERIALIZED (
			SELECT balances.balance_micro_usd, balances.withdrawable_micro_usd
			FROM balances, claim
			WHERE balances.account_id = $1 AND claim.owns_claim
			FOR UPDATE OF balances
		), debit AS (
			UPDATE balances AS b
			SET balance_micro_usd = b.balance_micro_usd - $2,
			    withdrawable_micro_usd = b.withdrawable_micro_usd -
			        GREATEST(0::bigint, $2 - (current.balance_micro_usd - current.withdrawable_micro_usd)),
			    updated_at = NOW()
			FROM current
			WHERE b.account_id = $1 AND current.balance_micro_usd >= $2
			RETURNING b.balance_micro_usd,
			          GREATEST(0::bigint, $2 - (current.balance_micro_usd - current.withdrawable_micro_usd))
			              AS withdrawable_micro_usd
		), record_provenance AS (
			UPDATE balance_reservation_operations AS operation
			SET withdrawable_micro_usd = debit.withdrawable_micro_usd
			FROM debit
			WHERE operation.operation_key = $3 AND operation.claim_token = $5
			RETURNING operation.withdrawable_micro_usd
		), ledger AS (
			INSERT INTO ledger_entries
				(account_id, entry_type, amount_micro_usd, balance_after, reference)
			SELECT $1, $4, -$2, balance_micro_usd, 'reserve:' || $3
			FROM debit
		)
		SELECT withdrawable_micro_usd, 'applied' FROM debit
		UNION ALL
		SELECT withdrawable_micro_usd, 'replayed' FROM claim
		WHERE NOT owns_claim AND account_id = $1 AND kind = 'reserve'
		  AND amount_micro_usd = $2
		UNION ALL
		SELECT 0, 'conflict' FROM claim
		WHERE NOT owns_claim
		  AND (account_id <> $1 OR kind <> 'reserve' OR amount_micro_usd <> $2)
		LIMIT 1`,
		accountID, amountMicroUSD, operationKey, string(LedgerCharge), claimToken,
	).Scan(&reservedWithdrawable, &disposition)
	if errors.Is(err, pgx.ErrNoRows) {
		if _, cleanupErr := s.pool.Exec(ctx,
			`DELETE FROM balance_reservation_operations
			 WHERE operation_key = $1 AND claim_token = $2`,
			operationKey, claimToken,
		); cleanupErr != nil {
			return 0, false, fmt.Errorf("store: clean rejected inference reservation: %w", cleanupErr)
		}
		return 0, false, ErrInsufficientBalance
	}
	if err != nil {
		return 0, false, fmt.Errorf("store: reserve inference balance: %w", err)
	}
	if disposition == "conflict" {
		return 0, false, ErrFinancialOperationConflict
	}
	return reservedWithdrawable, disposition == "applied", nil
}

func (s *PostgresStore) ReleaseInferenceReservation(accountID string, amountMicroUSD, withdrawableMicroUSD int64, operationKey, reference string) (bool, error) {
	if amountMicroUSD < 0 || withdrawableMicroUSD < 0 || withdrawableMicroUSD > amountMicroUSD || operationKey == "" {
		return false, ErrFinancialOperationConflict
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	claimToken := uuid.NewString()
	var disposition string
	err := s.pool.QueryRow(ctx, `
		WITH claim AS (
			INSERT INTO balance_reservation_operations
				(operation_key, account_id, kind, amount_micro_usd, withdrawable_micro_usd, claim_token)
			VALUES ($4, $1, 'release', $2, $3, $7)
			ON CONFLICT (operation_key) DO UPDATE
				SET operation_key = EXCLUDED.operation_key
			RETURNING account_id, kind, amount_micro_usd, withdrawable_micro_usd,
			          claim_token = $7 AS owns_claim
		), credit AS (
			INSERT INTO balances
				(account_id, balance_micro_usd, withdrawable_micro_usd, updated_at)
			SELECT $1, $2, $3, NOW()
			FROM claim
			WHERE owns_claim AND $2 > 0
			ON CONFLICT (account_id) DO UPDATE SET
				balance_micro_usd = balances.balance_micro_usd + $2,
				withdrawable_micro_usd = balances.withdrawable_micro_usd + $3,
				updated_at = NOW()
			RETURNING balance_micro_usd
		), ledger AS (
			INSERT INTO ledger_entries
				(account_id, entry_type, amount_micro_usd, balance_after, reference)
			SELECT $1, $5, $2, balance_micro_usd, $6
			FROM credit
		)
		SELECT 'applied' FROM claim WHERE owns_claim
		UNION ALL
		SELECT 'replayed' FROM claim
		WHERE NOT owns_claim AND account_id = $1 AND kind = 'release'
		  AND amount_micro_usd = $2 AND withdrawable_micro_usd = $3
		UNION ALL
		SELECT 'conflict' FROM claim
		WHERE NOT owns_claim
		  AND (account_id <> $1 OR kind <> 'release' OR amount_micro_usd <> $2
		       OR withdrawable_micro_usd <> $3)
		LIMIT 1`,
		accountID, amountMicroUSD, withdrawableMicroUSD, operationKey,
		string(LedgerRefund), reference, claimToken,
	).Scan(&disposition)
	if err != nil {
		return false, fmt.Errorf("store: release inference reservation: %w", err)
	}
	if disposition == "conflict" {
		return false, ErrFinancialOperationConflict
	}
	return disposition == "applied", nil
}
