package store

import "time"

// MaxStripeWithdrawalsByStatusLimit caps ListStripeWithdrawalsByStatus result
// sets. A limit <= 0 no longer means "unbounded" — reading the entire table
// into memory is never intended (threat-model review advisory).
const MaxStripeWithdrawalsByStatusLimit = 1000

// StripeWithdrawal records a user-initiated payout via Stripe Connect Express.
// The lifecycle is: pending (debit recorded) → transferred (platform→connected
// account transfer succeeded) → paid (Stripe payout to bank/card succeeded).
// On failure at any stage we re-credit the user via LedgerRefund and set the
// status to "failed".
type StripeWithdrawal struct {
	TransferDispatchAttempts int       `json:"-"`
	TransferAttempt          int       `json:"-"` // advanced only after a confirmed funding rejection
	TransferStartedAt        time.Time `json:"-"`
	TransferLeaseUntil       time.Time `json:"-"`
	ID                       string    `json:"id"`                        // internal UUID, used as Stripe idempotency key prefix
	AccountID                string    `json:"account_id"`                // internal account that owns the withdrawal
	StripeAccountID          string    `json:"stripe_account_id"`         // Stripe connected account (acct_…)
	TransferID               string    `json:"transfer_id,omitempty"`     // Stripe transfer (tr_…)
	PayoutID                 string    `json:"payout_id,omitempty"`       // Stripe payout (po_…) we created (instant path)
	SweepPayoutID            string    `json:"sweep_payout_id,omitempty"` // automatic sweep payout (po_…) that claimed this row as paid — lets a later payout.failed for the same sweep reopen it
	AmountMicroUSD           int64     `json:"amount_micro_usd"`          // gross amount debited from ledger
	FeeMicroUSD              int64     `json:"fee_micro_usd"`             // fee retained by platform
	NetMicroUSD              int64     `json:"net_micro_usd"`             // amount transferred to user (gross - fee)
	Method                   string    `json:"method"`                    // "standard" | "instant"
	Status                   string    `json:"status"`                    // "queued" | "pending" | "transferred" | "paid" | "failed"
	FailureReason            string    `json:"failure_reason,omitempty"`  // populated when Status="failed"
	Refunded                 bool      `json:"refunded,omitempty"`        // true after the failure refund is credited
	FeeRefunded              bool      `json:"fee_refunded,omitempty"`    // true after the instant fee is credited back (instant payout fell back to the standard sweep)
	CreatedAt                time.Time `json:"created_at"`
	UpdatedAt                time.Time `json:"updated_at"`
}

// ReconciliationStartedAt excludes funding waits from the stuck-withdrawal age.
// Historical pending rows without a dispatch timestamp retain their creation age.
func (w StripeWithdrawal) ReconciliationStartedAt() time.Time {
	switch w.Status {
	case "pending":
		if !w.TransferStartedAt.IsZero() {
			return w.TransferStartedAt
		}
	case "transferred":
		return w.UpdatedAt
	}
	return w.CreatedAt
}
