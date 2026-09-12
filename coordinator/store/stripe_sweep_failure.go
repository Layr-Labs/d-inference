package store

import (
	"context"
	"errors"
	"fmt"
	"time"
)

func (s *MemoryStore) ReopenStripeWithdrawalAfterSweepFailure(id, expectedSweepPayoutID, failureReason string) (bool, error) {
	if id == "" || expectedSweepPayoutID == "" {
		return false, errors.New("stripe withdrawal and sweep payout ids are required")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	w, ok := s.stripeWithdrawalsByID[id]
	if !ok || w.Status != "paid" || w.Refunded || w.SweepPayoutID != expectedSweepPayoutID {
		return false, nil
	}
	w.Status = "transferred"
	w.SweepPayoutID = ""
	w.FailureReason = failureReason
	w.UpdatedAt = time.Now()
	return true, nil
}

func (s *PostgresStore) ReopenStripeWithdrawalAfterSweepFailure(id, expectedSweepPayoutID, failureReason string) (bool, error) {
	if id == "" || expectedSweepPayoutID == "" {
		return false, errors.New("stripe withdrawal and sweep payout ids are required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tag, err := s.pool.Exec(ctx, `
		UPDATE stripe_withdrawals
		SET status = 'transferred', sweep_payout_id = '', failure_reason = $3, updated_at = NOW()
		WHERE id = $1 AND sweep_payout_id = $2 AND status = 'paid' AND refunded = FALSE`,
		id, expectedSweepPayoutID, failureReason)
	if err != nil {
		return false, fmt.Errorf("store: reopen stripe withdrawal after sweep failure: %w", err)
	}
	return tag.RowsAffected() > 0, nil
}
