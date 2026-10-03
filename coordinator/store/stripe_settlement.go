package store

import (
	"errors"
	"strings"
)

// A durable first-attempt rejection permits automatic refund recovery. Historical
// unmarked failures require Stripe-side verification before an operator promotes
// them to this state; missing transfer IDs alone do not establish non-payment.
const StripeConfirmedRejectionPrefix = "transfer_create_failed: confirmed_rejection: "

// ErrCheckoutErased: the billing session belongs to an erased account. The
// scrub marks a pending session "erased" and clears its Checkout ID; a later
// checkout.session.completed is acknowledged and refunded by hand.
var ErrCheckoutErased = errors.New("billing session belongs to an erased account")

type StripeSettlementStore interface {
	ListStripeRefundsToRecover(limit int) ([]StripeWithdrawal, error)
	RecordStripeTransferRejection(id, reason string) error
	RefundRejectedStripeWithdrawal(id string) (bool, error)
	CompleteStripeCheckout(sessionID, externalID, accountID string, amountMicroUSD int64) (bool, error)
}

func StripeRefundRecoverable(w *StripeWithdrawal) bool {
	return w != nil && w.AmountMicroUSD > 0 && w.Status == "failed" && !w.Refunded && w.TransferID == "" && w.PayoutID == "" && w.SweepPayoutID == "" && strings.HasPrefix(w.FailureReason, StripeConfirmedRejectionPrefix)
}

func stripeRejectionAllowed(w *StripeWithdrawal, reason string) bool {
	return reason != "" && w != nil && !w.Refunded && w.TransferID == "" && w.PayoutID == "" && w.SweepPayoutID == "" && (w.Status == "pending" || (w.Status == "failed" && strings.HasPrefix(w.FailureReason, "transfer_create_failed:")))
}

func checkoutMatches(s *BillingSession, externalID, accountID string, amount int64) bool {
	return s != nil && externalID != "" && accountID != "" && amount > 0 && s.PaymentMethod == "stripe" && s.ExternalID == externalID && s.AccountID == accountID && s.AmountMicroUSD == amount && (s.Status == "pending" || s.Status == "completed")
}
