package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

func (s *MemoryStore) RefundStripeWithdrawalAfterReversal(id, expectedTransferID string) (bool, error) {
	if id == "" || expectedTransferID == "" {
		return false, errors.New("stripe withdrawal and transfer ids are required")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	wd, ok := s.stripeWithdrawalsByID[id]
	if !ok {
		return false, fmt.Errorf("stripe withdrawal %q: %w", id, ErrNotFound)
	}
	if wd.Status == "paid" || wd.Refunded || wd.TransferID != expectedTransferID {
		return false, nil
	}
	for _, refund := range stripeReversalRefunds(wd) {
		if refund.amount > 0 {
			s.creditWithdrawableOnceLocked(wd.AccountID, refund.amount, LedgerRefund, refund.reference)
		}
	}
	wd.Status, wd.Refunded = "failed", true
	wd.FeeRefunded = wd.FeeRefunded || wd.FeeMicroUSD > 0
	wd.FailureReason, wd.UpdatedAt = "transfer_reversed", time.Now()
	return true, nil
}

func (s *PostgresStore) RefundStripeWithdrawalAfterReversal(id, expectedTransferID string) (bool, error) {
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
			return false, fmt.Errorf("stripe withdrawal %q: %w", id, ErrNotFound)
		}
		return false, fmt.Errorf("store: lock reversal withdrawal: %w", err)
	}
	if wd.Status == "paid" || wd.Refunded || wd.TransferID != expectedTransferID {
		return false, nil
	}
	refunds := stripeReversalRefunds(wd)
	// Lock both references before touching the account balance. Otherwise an
	// independent fee refund could hold its reference while waiting for our
	// balance lock, as this transaction waits for that same fee reference.
	for _, refund := range refunds {
		if refund.amount > 0 {
			if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, string(LedgerRefund)+":"+refund.reference); err != nil {
				return false, fmt.Errorf("store: lock reversal refund: %w", err)
			}
		}
	}
	for _, refund := range refunds {
		if refund.amount > 0 {
			if _, err := creditWithdrawableOnceTx(ctx, tx, wd.AccountID, refund.amount, LedgerRefund, refund.reference); err != nil {
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

type stripeReversalRefund struct {
	amount    int64
	reference string
}

func stripeReversalRefunds(wd *StripeWithdrawal) [2]stripeReversalRefund {
	return [2]stripeReversalRefund{
		{wd.AmountMicroUSD - wd.FeeMicroUSD, "stripe_withdraw:" + wd.ID},
		{wd.FeeMicroUSD, "stripe_withdraw_fee:" + wd.ID},
	}
}
