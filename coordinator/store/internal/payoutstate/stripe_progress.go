package payoutstate

import (
	"errors"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

type StripeProgress struct {
	TransferID, PayoutID, SweepPayoutID, Status, FailureReason string
	Refunded, FeeRefunded                                      bool
}

func StripeProgressOf(w *contracts.StripeWithdrawal) StripeProgress {
	return StripeProgress{w.TransferID, w.PayoutID, w.SweepPayoutID, w.Status, w.FailureReason, w.Refunded, w.FeeRefunded}
}

func ValidateStripeUpdate(previous, next *contracts.StripeWithdrawal) error {
	if previous == nil || next == nil || next.ID == "" || previous.ID != next.ID {
		return errors.New("matching stripe withdrawal ids are required")
	}
	return nil
}
