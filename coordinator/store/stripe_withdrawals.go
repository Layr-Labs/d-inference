package store

import "time"

// StripeWithdrawalStore covers user-initiated bank/card payouts via Stripe
// Connect Express.
type StripeWithdrawalStore interface {
	// CreateStripeWithdrawal stores a new withdrawal record. The caller is
	// responsible for debiting the ledger atomically before calling this.
	CreateStripeWithdrawal(withdrawal *StripeWithdrawal) error

	// GetStripeWithdrawal returns a withdrawal by its internal UUID.
	GetStripeWithdrawal(id string) (*StripeWithdrawal, error)

	// GetStripeWithdrawalByPayoutID looks up a withdrawal by Stripe payout ID
	// (po_…). Used in payout.paid / payout.failed webhook handlers.
	GetStripeWithdrawalByPayoutID(payoutID string) (*StripeWithdrawal, error)

	// GetStripeWithdrawalByTransferID looks up a withdrawal by Stripe transfer
	// ID (tr_…). Used in transfer.failed webhook handlers.
	GetStripeWithdrawalByTransferID(transferID string) (*StripeWithdrawal, error)

	// UpdateStripeWithdrawal persists status/transfer/payout/fail-reason changes.
	UpdateStripeWithdrawal(withdrawal *StripeWithdrawal) error

	// ListStripeWithdrawals returns withdrawals for an account, newest first.
	// Pass limit <= 0 for no limit.
	ListStripeWithdrawals(accountID string, limit int) ([]StripeWithdrawal, error)
}

// StripeWithdrawal records a user-initiated payout via Stripe Connect Express.
// The lifecycle is: pending (debit recorded) → transferred (platform→connected
// account transfer succeeded) → paid (Stripe payout to bank/card succeeded).
// On failure at any stage we re-credit the user via LedgerRefund and set the
// status to "failed".
type StripeWithdrawal struct {
	ID              string    `json:"id"`                       // internal UUID, used as Stripe idempotency key prefix
	AccountID       string    `json:"account_id"`               // internal account that owns the withdrawal
	StripeAccountID string    `json:"stripe_account_id"`        // Stripe connected account (acct_…)
	TransferID      string    `json:"transfer_id,omitempty"`    // Stripe transfer (tr_…)
	PayoutID        string    `json:"payout_id,omitempty"`      // Stripe payout (po_…)
	AmountMicroUSD  int64     `json:"amount_micro_usd"`         // gross amount debited from ledger
	FeeMicroUSD     int64     `json:"fee_micro_usd"`            // fee retained by platform
	NetMicroUSD     int64     `json:"net_micro_usd"`            // amount transferred to user (gross - fee)
	Method          string    `json:"method"`                   // "standard" | "instant"
	Status          string    `json:"status"`                   // "pending" | "transferred" | "paid" | "failed"
	FailureReason   string    `json:"failure_reason,omitempty"` // populated when Status="failed"
	Refunded        bool      `json:"refunded,omitempty"`       // true after the failure refund is credited
	CreatedAt       time.Time `json:"created_at"`
	UpdatedAt       time.Time `json:"updated_at"`
}
