package store

import "time"

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

// PaymentRecord captures a settled payment.
type PaymentRecord struct {
	TxHash           string    `json:"tx_hash"`
	ConsumerAddress  string    `json:"consumer_address"`
	ProviderAddress  string    `json:"provider_address"`
	AmountUSD        string    `json:"amount_usd"`
	Model            string    `json:"model"`
	PromptTokens     int       `json:"prompt_tokens"`
	CompletionTokens int       `json:"completion_tokens"`
	Memo             string    `json:"memo"`
	CreatedAt        time.Time `json:"created_at"`
}

// Referrer represents a registered referral partner.
type Referrer struct {
	AccountID string    `json:"account_id"`
	Code      string    `json:"code"`
	CreatedAt time.Time `json:"created_at"`
}

// ReferralStats provides aggregate metrics for a referral code.
type ReferralStats struct {
	Code                 string `json:"code"`
	TotalReferred        int    `json:"total_referred"`
	TotalRewardsMicroUSD int64  `json:"total_rewards_micro_usd"`
}

// ModelPrice represents a custom per-model price override for an account.
type ModelPrice struct {
	AccountID   string `json:"account_id"`
	Model       string `json:"model"`
	InputPrice  int64  `json:"input_price"`  // micro-USD per 1M tokens
	OutputPrice int64  `json:"output_price"` // micro-USD per 1M tokens
}

// Per-key spend-cap reset windows. A cap with KeyResetNone is a lifetime cap;
// the others reset at the corresponding UTC calendar boundary (midnight UTC for
// daily, Monday 00:00 UTC for weekly, the 1st 00:00 UTC for monthly).
const (
	KeyResetNone    = "none"
	KeyResetDaily   = "daily"
	KeyResetWeekly  = "weekly"
	KeyResetMonthly = "monthly"
)
