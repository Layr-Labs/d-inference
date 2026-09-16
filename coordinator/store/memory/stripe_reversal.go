package memory

import (
	"errors"
	"fmt"
	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/payoutstate"
	"time"
)

func (s *Store) RefundStripeWithdrawalAfterReversal(id, expectedTransferID string) (bool, error) {
	if id == "" || expectedTransferID == "" {
		return false, errors.New("stripe withdrawal and transfer ids are required")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	wd, ok := s.stripeWithdrawalsByID[id]
	if !ok {
		return false, fmt.Errorf("stripe withdrawal %q: %w", id, contracts.ErrNotFound)
	}
	if wd.Status == "paid" || wd.Refunded || wd.TransferID != expectedTransferID {
		return false, nil
	}
	for _, refund := range payoutstate.StripeReversalRefunds(wd) {
		if refund.Amount > 0 {
			s.creditWithdrawableOnceLocked(wd.AccountID, refund.Amount, contracts.LedgerRefund, refund.Reference)
		}
	}
	wd.Status, wd.Refunded = "failed", true
	wd.FeeRefunded = wd.FeeRefunded || wd.FeeMicroUSD > 0
	wd.FailureReason, wd.UpdatedAt = "transfer_reversed", time.Now()
	return true, nil
}
