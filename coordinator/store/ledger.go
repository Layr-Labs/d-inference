package store

import (
	"errors"
	"time"
)

// ErrInsufficientBalance is returned by Debit when the account has
// insufficient funds (or does not exist). Callers should check with
// errors.Is to distinguish this from transient DB errors.
var ErrInsufficientBalance = errors.New("insufficient balance or account not found")

// LedgerStore covers the double-entry balance ledger (all amounts in micro-USD)
// including the withdrawable subset and atomic balance migration.
type LedgerStore interface {
	// GetBalance returns the current balance in micro-USD for an account.
	GetBalance(accountID string) int64

	// Credit adds micro-USD to an account and records the ledger entry.
	Credit(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error

	// Debit subtracts micro-USD from an account. Returns error if insufficient funds.
	Debit(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error

	// GetWithdrawableBalance returns the withdrawable balance in micro-USD.
	GetWithdrawableBalance(accountID string) int64

	// GetBalanceWithWithdrawable returns both the total balance and the
	// withdrawable balance in a single query, avoiding two round trips to
	// the same row in the balances table.
	GetBalanceWithWithdrawable(accountID string) (balance int64, withdrawable int64)

	// CreditWithdrawable adds micro-USD to both the total balance and the
	// withdrawable balance, and records a ledger entry. Use for provider
	// earnings, referral rewards, and admin rewards.
	CreditWithdrawable(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error

	// DebitWithdrawable subtracts micro-USD from both the total balance and
	// the withdrawable balance atomically. Returns error if withdrawable
	// balance is insufficient. Use for Stripe Connect withdrawals so the
	// debit is symmetric with CreditWithdrawable refunds.
	DebitWithdrawable(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error

	// LedgerHistory returns ledger entries for an account, newest first.
	LedgerHistory(accountID string) []LedgerEntry

	// MigrateAccountBalance atomically moves the entire balance (and its
	// withdrawable subset) from one account ID to another, merging into the
	// destination, and records ledger entries on both sides. Returns moved=true
	// when funds were transferred; it is a no-op (moved=false) when the source
	// has no balance. Used to carry an unlinked legacy key's funds from its old
	// raw-token identity to the hashed identity (see LegacyAccountID).
	MigrateAccountBalance(from, to string) (moved bool, err error)
}

// LedgerEntryType categorizes balance changes.
type LedgerEntryType string

const (
	LedgerDeposit        LedgerEntryType = "deposit"         // consumer funds account
	LedgerCharge         LedgerEntryType = "charge"          // consumer pays for inference
	LedgerPayout         LedgerEntryType = "payout"          // provider credited for serving
	LedgerPlatformFee    LedgerEntryType = "platform_fee"    // Darkbloom platform cut
	LedgerWithdrawal     LedgerEntryType = "withdrawal"      // on-chain withdrawal
	LedgerReferralReward LedgerEntryType = "referral_reward" // referrer earns share of platform fee
	LedgerStripeDeposit  LedgerEntryType = "stripe_deposit"  // Stripe checkout deposit
	LedgerStripePayout   LedgerEntryType = "stripe_payout"   // user-initiated bank/card withdrawal via Stripe Connect
	LedgerInviteCredit   LedgerEntryType = "invite_credit"   // invite code redemption
	LedgerRefund         LedgerEntryType = "refund"          // reservation refund (request failed before inference)
	LedgerAdminCredit    LedgerEntryType = "admin_credit"    // admin-granted non-withdrawable credit
	LedgerAdminReward    LedgerEntryType = "admin_reward"    // admin-granted withdrawable reward
	LedgerMigration      LedgerEntryType = "migration"       // balance moved between account identities (e.g. legacy key re-keying)
)

// LedgerEntry is a single balance-changing event.
type LedgerEntry struct {
	ID             int64           `json:"id"`
	AccountID      string          `json:"account_id"`
	Type           LedgerEntryType `json:"type"`
	AmountMicroUSD int64           `json:"amount_micro_usd"` // positive = credit, negative = debit
	BalanceAfter   int64           `json:"balance_after"`
	Reference      string          `json:"reference"` // job ID, tx hash, etc.
	CreatedAt      time.Time       `json:"created_at"`
}
