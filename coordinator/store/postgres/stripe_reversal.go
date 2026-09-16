package postgres

import (
	"context"
	"errors"
	"fmt"
	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/payoutstate"
	"github.com/jackc/pgx/v5"
	"time"
)

func (s *Store) RefundStripeWithdrawalAfterReversal(id, expectedTransferID string) (bool, error) {
	if id == "" || expectedTransferID == "" {
		return false, errors.New("stripe withdrawal and transfer ids are required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, fmt.Errorf("store: begin reversal: %w", err)
	}
	defer tx.Rollback(ctx)
	wd, err := scanStripeWithdrawal(tx.QueryRow(ctx,
		`SELECT `+stripeWithdrawalSelectColumns+` FROM stripe_withdrawals WHERE id = $1 FOR UPDATE`, id))
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return false, fmt.Errorf("stripe withdrawal %q: %w", id, contracts.ErrNotFound)
		}
		return false, fmt.Errorf("store: lock reversal withdrawal: %w", err)
	}
	if wd.Status == "paid" || wd.Refunded || wd.TransferID != expectedTransferID {
		return false, nil
	}
	refunds := payoutstate.StripeReversalRefunds(wd)
	// Lock both references before touching the account balance. Otherwise an
	// independent fee refund could hold its reference while waiting for our
	// balance lock, as this transaction waits for that same fee reference.
	for _, refund := range refunds {
		if refund.Amount > 0 {
			if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, string(contracts.LedgerRefund)+":"+refund.Reference); err != nil {
				return false, fmt.Errorf("store: lock reversal refund: %w", err)
			}
		}
	}
	for _, refund := range refunds {
		if refund.Amount > 0 {
			if _, err := creditWithdrawableOnceTx(ctx, tx, wd.AccountID, refund.Amount, contracts.LedgerRefund, refund.Reference); err != nil {
				return false, err
			}
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE stripe_withdrawals
		SET status = 'failed', refunded = TRUE,
		    fee_refunded = (fee_refunded OR fee_micro_usd > 0),
		    failure_reason = 'transfer_reversed', updated_at = NOW()
		WHERE id = $1`, id); err != nil {
		return false, fmt.Errorf("store: persist reversal: %w", err)
	}
	return true, tx.Commit(ctx)
}
