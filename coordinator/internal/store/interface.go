// Package store provides storage backends for API keys, usage tracking,
// balance management, and payment records.
//
// Two implementations are provided:
//   - MemoryStore: In-memory storage for development and testing. Data is
//     lost on restart. Suitable for single-instance coordinators.
//   - PostgresStore: PostgreSQL-backed storage for production. Provides
//     persistence, atomic balance operations, and multi-instance support.
//
// The store also manages a double-entry ledger for consumer and provider
// balances. All monetary amounts are in micro-USD (1 USD = 1,000,000
// micro-USD), which maps 1:1 to pathUSD's 6-decimal on-chain representation
// on the Tempo blockchain.
package store

import "time"

// Store is the interface that all storage backends must implement.
type Store interface {
	// CreateKey generates a new API key, persists it, and returns it.
	CreateKey() (string, error)

	// ValidateKey returns true if the given key exists and is active.
	ValidateKey(key string) bool

	// RevokeKey deactivates a key. Returns true if the key existed.
	RevokeKey(key string) bool

	// RecordUsage logs an inference usage event.
	RecordUsage(providerID, consumerKey, model string, promptTokens, completionTokens int)

	// RecordPayment records a settled payment between consumer and provider.
	RecordPayment(txHash, consumerAddr, providerAddr, amountUSD, model string, promptTokens, completionTokens int, memo string) error

	// UsageRecords returns all usage records.
	UsageRecords() []UsageRecord

	// KeyCount returns the number of active API keys.
	KeyCount() int

	// --- Balance Ledger ---

	// GetBalance returns the current balance in micro-USD for an account.
	GetBalance(accountID string) int64

	// Credit adds micro-USD to an account and records the ledger entry.
	Credit(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error

	// Debit subtracts micro-USD from an account. Returns error if insufficient funds.
	Debit(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error

	// LedgerHistory returns ledger entries for an account, newest first.
	LedgerHistory(accountID string) []LedgerEntry

	// --- Referral System ---

	// CreateReferrer registers an account as a referrer with the given code.
	CreateReferrer(accountID, code string) error

	// GetReferrerByCode returns the referrer for a given referral code.
	GetReferrerByCode(code string) (*Referrer, error)

	// GetReferrerByAccount returns the referrer record for an account, if registered.
	GetReferrerByAccount(accountID string) (*Referrer, error)

	// RecordReferral records that referredAccountID was referred by referrerCode.
	RecordReferral(referrerCode, referredAccountID string) error

	// GetReferrerForAccount returns the referrer code that referred this account, or "" if none.
	GetReferrerForAccount(accountID string) (string, error)

	// GetReferralStats returns referral statistics for a code.
	GetReferralStats(code string) (*ReferralStats, error)

	// --- Billing Sessions ---

	// CreateBillingSession stores a new billing session (Stripe, EVM, Solana).
	CreateBillingSession(session *BillingSession) error

	// GetBillingSession retrieves a billing session by ID.
	GetBillingSession(sessionID string) (*BillingSession, error)

	// CompleteBillingSession marks a session as completed and sets the completion time.
	CompleteBillingSession(sessionID string) error

	// IsExternalIDProcessed returns true if a billing session with this external ID
	// has already been completed. Used to prevent double-crediting the same on-chain tx.
	IsExternalIDProcessed(externalID string) bool

	// --- Users (Privy) ---

	// CreateUser creates a new user record linked to a Privy identity.
	CreateUser(user *User) error

	// GetUserByPrivyID returns the user for a Privy DID.
	GetUserByPrivyID(privyUserID string) (*User, error)

	// GetUserByAccountID returns the user for an internal account ID.
	GetUserByAccountID(accountID string) (*User, error)
}

// UsageRecord captures a single inference usage event.
type UsageRecord struct {
	ProviderID       string    `json:"provider_id"`
	ConsumerKey      string    `json:"consumer_key"`
	Model            string    `json:"model"`
	PromptTokens     int       `json:"prompt_tokens"`
	CompletionTokens int       `json:"completion_tokens"`
	Timestamp        time.Time `json:"timestamp"`
}

// LedgerEntryType categorizes balance changes.
type LedgerEntryType string

const (
	LedgerDeposit        LedgerEntryType = "deposit"         // consumer funds account
	LedgerCharge         LedgerEntryType = "charge"          // consumer pays for inference
	LedgerPayout         LedgerEntryType = "payout"          // provider credited for serving
	LedgerPlatformFee    LedgerEntryType = "platform_fee"    // DGInf platform cut
	LedgerWithdrawal     LedgerEntryType = "withdrawal"      // on-chain withdrawal
	LedgerReferralReward LedgerEntryType = "referral_reward" // referrer earns share of platform fee
	LedgerStripeDeposit  LedgerEntryType = "stripe_deposit"  // Stripe checkout deposit
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
	TxHash          string    `json:"tx_hash"`
	ConsumerAddress string    `json:"consumer_address"`
	ProviderAddress string    `json:"provider_address"`
	AmountUSD       string    `json:"amount_usd"`
	Model           string    `json:"model"`
	PromptTokens    int       `json:"prompt_tokens"`
	CompletionTokens int      `json:"completion_tokens"`
	Memo            string    `json:"memo"`
	CreatedAt       time.Time `json:"created_at"`
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

// User represents a consumer account linked to a Privy identity.
type User struct {
	AccountID           string    `json:"account_id"`            // internal account ID (used in ledger)
	PrivyUserID         string    `json:"privy_user_id"`         // Privy DID (e.g. "did:privy:abc123")
	SolanaWalletAddress string    `json:"solana_wallet_address"` // embedded wallet public address
	SolanaWalletID      string    `json:"solana_wallet_id"`      // Privy's internal wallet ID (for signing API)
	CreatedAt           time.Time `json:"created_at"`
}

// BillingSession tracks an in-progress payment via any method (Stripe, EVM, Solana).
type BillingSession struct {
	ID             string     `json:"id"`
	AccountID      string     `json:"account_id"`
	PaymentMethod  string     `json:"payment_method"` // "stripe", "evm", "solana"
	Chain          string     `json:"chain"`           // "ethereum", "tempo", "solana", ""
	AmountMicroUSD int64      `json:"amount_micro_usd"`
	ExternalID     string     `json:"external_id"`     // Stripe session ID, tx hash, etc.
	Status         string     `json:"status"`          // "pending", "completed", "expired"
	ReferralCode   string     `json:"referral_code"`   // optional
	CreatedAt      time.Time  `json:"created_at"`
	CompletedAt    *time.Time `json:"completed_at,omitempty"`
}
