package contracts

import (
	"time"
)

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
	ID              string    `json:"id"`                        // internal UUID, used as Stripe idempotency key prefix
	AccountID       string    `json:"account_id"`                // internal account that owns the withdrawal
	StripeAccountID string    `json:"stripe_account_id"`         // Stripe connected account (acct_…)
	TransferID      string    `json:"transfer_id,omitempty"`     // Stripe transfer (tr_…)
	PayoutID        string    `json:"payout_id,omitempty"`       // Stripe payout (po_…) we created (instant path)
	SweepPayoutID   string    `json:"sweep_payout_id,omitempty"` // automatic sweep payout (po_…) that claimed this row as paid — lets a later payout.failed for the same sweep reopen it
	AmountMicroUSD  int64     `json:"amount_micro_usd"`          // gross amount debited from ledger
	FeeMicroUSD     int64     `json:"fee_micro_usd"`             // fee retained by platform
	NetMicroUSD     int64     `json:"net_micro_usd"`             // amount transferred to user (gross - fee)
	Method          string    `json:"method"`                    // "standard" | "instant"
	Status          string    `json:"status"`                    // "pending" | "transferred" | "paid" | "failed"
	FailureReason   string    `json:"failure_reason,omitempty"`  // populated when Status="failed"
	Refunded        bool      `json:"refunded,omitempty"`        // true after the failure refund is credited
	FeeRefunded     bool      `json:"fee_refunded,omitempty"`    // true after the instant fee is credited back (instant payout fell back to the standard sweep)
	CreatedAt       time.Time `json:"created_at"`
	UpdatedAt       time.Time `json:"updated_at"`
}

// StripeWithdrawalStore owns withdrawal state and atomic balance transitions.
type StripeWithdrawalStore interface {
	// --- Stripe Withdrawals (bank/card payouts via Stripe Connect) ---

	// CreateStripeWithdrawal stores a new withdrawal record. The caller is
	// responsible for debiting the ledger atomically before calling this.
	CreateStripeWithdrawal(withdrawal *StripeWithdrawal) error

	// CreateStripeWithdrawalWithDebit atomically debits both the balance and
	// withdrawable columns (recording a ledger entry with the given type and
	// reference) AND inserts the withdrawal row in a single transaction —
	// either both happen or neither, closing the crash window between a
	// ledger debit and its withdrawal row. Returns ErrInsufficientBalance
	// (checkable with errors.Is) when the account can't cover the debit.
	CreateStripeWithdrawalWithDebit(withdrawal *StripeWithdrawal, entryType LedgerEntryType, reference string) error

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

	// MarkStripeWithdrawalPaid atomically flips a withdrawal to "paid" —
	// but only from a non-terminal, non-refunded state ("pending" or
	// "transferred" with Refunded=false) AND only while the row's PayoutID
	// still equals expectedPayoutID ("" = the row must have no in-flight
	// payout, the sweep case). Guarding inside the store closes the
	// read-modify-write races between concurrent webhook deliveries:
	// a stale copy can never overwrite Refunded/failed state back to paid,
	// and a payout.paid whose payout was concurrently detached (bounced)
	// can't re-claim the reopened row. A non-empty sweepPayoutID is
	// recorded on the row (sweep attribution). Returns whether the flip
	// was applied.
	MarkStripeWithdrawalPaid(id, expectedPayoutID, sweepPayoutID string) (bool, error)

	// ReopenStripeWithdrawalAfterPayoutFailure atomically reopens a
	// withdrawal whose own payout failed: status back to "transferred",
	// payout ID detached, failure reason recorded, FeeRefunded OR-ed in —
	// but only while the row is not refunded and not terminally failed
	// (a concurrent transfer.reversed wins; its refund must never be
	// overwritten back to sweep-eligible). Returns whether it was applied.
	ReopenStripeWithdrawalAfterPayoutFailure(id, failureReason string, feeRefunded bool) (bool, error)

	// ListStripeWithdrawalsBySweepPayoutID returns the withdrawals a given
	// automatic sweep payout claimed (SweepPayoutID stamp). Used to reopen
	// exactly those rows when the sweep later bounces.
	ListStripeWithdrawalsBySweepPayoutID(sweepPayoutID string) ([]StripeWithdrawal, error)

	// ListStripeWithdrawals returns withdrawals for an account, newest first.
	// Pass limit <= 0 for no limit.
	ListStripeWithdrawals(accountID string, limit int) ([]StripeWithdrawal, error)

	// ListStripeWithdrawalsByStatus returns up to limit withdrawals in the
	// given status created before olderThan, oldest first. Used by the payout
	// reconciler to find withdrawals stuck in "transferred". A limit <= 0 (or
	// above MaxStripeWithdrawalsByStatusLimit) is capped at
	// MaxStripeWithdrawalsByStatusLimit — the result set is never unbounded.
	ListStripeWithdrawalsByStatus(status string, olderThan time.Time, limit int) ([]StripeWithdrawal, error)

	// ListStripeWithdrawalsForStripeAccount returns withdrawals destined for
	// the given connected account (acct_…) in the given status, oldest first.
	// Used to resolve Stripe's automatic sweep payouts (whose IDs we never
	// see at creation time) back to local withdrawal rows.
	ListStripeWithdrawalsForStripeAccount(stripeAccountID, status string) ([]StripeWithdrawal, error)
}
