package store

import "strings"

// A durable first-attempt rejection permits automatic refund recovery. Historical
// unmarked failures require Stripe-side verification before an operator promotes
// them to this state; missing transfer IDs alone do not establish non-payment.
const StripeConfirmedRejectionPrefix = "transfer_create_failed: confirmed_rejection: "

type StripeSettlementStore interface {
	ListStripeRefundsToRecover(limit int) ([]StripeWithdrawal, error)
	RecordStripeTransferRejection(id, reason string) error
	RefundRejectedStripeWithdrawal(id string) (bool, error)
	CompleteStripeCheckout(sessionID, externalID, accountID string, amountMicroUSD int64) (bool, error)
}

func StripeRefundRecoverable(w *StripeWithdrawal) bool {
	return w != nil && w.AmountMicroUSD > 0 && w.Status == "failed" && !w.Refunded && w.TransferID == "" && w.PayoutID == "" && w.SweepPayoutID == "" && strings.HasPrefix(w.FailureReason, StripeConfirmedRejectionPrefix)
}
