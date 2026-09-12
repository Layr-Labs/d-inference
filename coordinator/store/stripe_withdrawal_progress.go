package store

import (
	"context"
	"errors"
	"fmt"
	"time"
)

// withdrawalProgress is the mutable state shared by submission and webhook
// writers. Account, amounts, method and creation time are never progress fields.
type withdrawalProgress struct {
	TransferID, PayoutID, SweepPayoutID, Status, FailureReason string
	Refunded, FeeRefunded                                      bool
}

func progressOf(w *StripeWithdrawal) withdrawalProgress {
	return withdrawalProgress{w.TransferID, w.PayoutID, w.SweepPayoutID, w.Status, w.FailureReason, w.Refunded, w.FeeRefunded}
}

func validWithdrawalUpdate(previous, next *StripeWithdrawal) error {
	if previous == nil || next == nil || next.ID == "" || previous.ID != next.ID {
		return errors.New("matching stripe withdrawal ids are required")
	}
	return nil
}

func (s *MemoryStore) CompareAndSwapStripeWithdrawal(previous, next *StripeWithdrawal) (bool, error) {
	if err := validWithdrawalUpdate(previous, next); err != nil {
		return false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	current := s.stripeWithdrawalsByID[next.ID]
	if current == nil {
		return false, nil
	}
	currentState, nextState := progressOf(current), progressOf(next)
	if currentState == nextState {
		return true, nil
	}
	if currentState != progressOf(previous) {
		return false, nil
	}
	if current.TransferID != next.TransferID {
		delete(s.stripeWithdrawalsByTransferID, current.TransferID)
		if next.TransferID != "" {
			s.stripeWithdrawalsByTransferID[next.TransferID] = next.ID
		}
	}
	if current.PayoutID != next.PayoutID {
		delete(s.stripeWithdrawalsByPayoutID, current.PayoutID)
		if next.PayoutID != "" {
			s.stripeWithdrawalsByPayoutID[next.PayoutID] = next.ID
		}
	}
	current.TransferID = next.TransferID
	current.PayoutID = next.PayoutID
	current.SweepPayoutID = next.SweepPayoutID
	current.Status = next.Status
	current.FailureReason = next.FailureReason
	current.Refunded = next.Refunded
	current.FeeRefunded = next.FeeRefunded
	current.UpdatedAt = time.Now()
	return true, nil
}

func (s *PostgresStore) CompareAndSwapStripeWithdrawal(previous, next *StripeWithdrawal) (bool, error) {
	if err := validWithdrawalUpdate(previous, next); err != nil {
		return false, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	// The desired-state arm recognizes a successful write whose acknowledgement
	// was lost. Only the expected-state arm changes fields or the timestamp.
	tag, err := s.pool.Exec(ctx, `UPDATE stripe_withdrawals SET
 transfer_id=$2,payout_id=$3,sweep_payout_id=$4,status=$5,
 failure_reason=$6,refunded=$7,fee_refunded=$8,
 updated_at=CASE WHEN ROW(transfer_id,payout_id,sweep_payout_id,status,failure_reason,refunded,fee_refunded)
 IS NOT DISTINCT FROM ROW($2::text,$3::text,$4::text,$5::text,$6::text,$7::boolean,$8::boolean)
 THEN updated_at ELSE NOW() END
 WHERE id=$1 AND (
 ROW(transfer_id,payout_id,sweep_payout_id,status,failure_reason,refunded,fee_refunded)
 IS NOT DISTINCT FROM ROW($9::text,$10::text,$11::text,$12::text,$13::text,$14::boolean,$15::boolean)
 OR ROW(transfer_id,payout_id,sweep_payout_id,status,failure_reason,refunded,fee_refunded)
 IS NOT DISTINCT FROM ROW($2::text,$3::text,$4::text,$5::text,$6::text,$7::boolean,$8::boolean))`,
		next.ID, next.TransferID, next.PayoutID, next.SweepPayoutID, next.Status, next.FailureReason, next.Refunded, next.FeeRefunded,
		previous.TransferID, previous.PayoutID, previous.SweepPayoutID, previous.Status, previous.FailureReason, previous.Refunded, previous.FeeRefunded)
	if err != nil {
		return false, fmt.Errorf("store: compare stripe withdrawal progress: %w", err)
	}
	return tag.RowsAffected() > 0, nil
}
