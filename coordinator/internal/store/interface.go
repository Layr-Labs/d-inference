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
	LedgerDeposit     LedgerEntryType = "deposit"      // consumer funds account
	LedgerCharge      LedgerEntryType = "charge"        // consumer pays for inference
	LedgerPayout      LedgerEntryType = "payout"        // provider credited for serving
	LedgerPlatformFee LedgerEntryType = "platform_fee"  // DGInf platform cut
	LedgerWithdrawal  LedgerEntryType = "withdrawal"    // on-chain withdrawal
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
