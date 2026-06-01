package store

import "time"

// ProviderEarningsStore covers per-node provider earnings and payouts,
// including the atomic credit-to-account and credit-to-wallet paths.
type ProviderEarningsStore interface {
	// RecordProviderEarning stores an earning record for a specific provider node.
	RecordProviderEarning(earning *ProviderEarning) error

	// GetProviderEarnings returns earnings for a specific provider node (by public key), newest first.
	GetProviderEarnings(providerKey string, limit int) ([]ProviderEarning, error)

	// GetAccountEarnings returns all earnings across all nodes for an account, newest first.
	GetAccountEarnings(accountID string, limit int) ([]ProviderEarning, error)

	// GetProviderEarningsSummary returns lifetime aggregates for a provider node.
	GetProviderEarningsSummary(providerKey string) (ProviderEarningsSummary, error)

	// GetAccountEarningsSummary returns lifetime aggregates for an account across all linked nodes.
	GetAccountEarningsSummary(accountID string) (ProviderEarningsSummary, error)

	// RecordProviderPayout stores a payout record for a provider wallet.
	RecordProviderPayout(payout *ProviderPayout) error

	// ListProviderPayouts returns all provider payout records in creation order.
	ListProviderPayouts() ([]ProviderPayout, error)

	// SettleProviderPayout marks a provider payout as settled.
	SettleProviderPayout(id int64) error

	// CreditProviderAccount atomically credits a linked provider account and
	// records the corresponding per-node earning.
	CreditProviderAccount(earning *ProviderEarning) error

	// CreditProviderWallet atomically credits an unlinked provider wallet and
	// records the corresponding payout history row.
	CreditProviderWallet(payout *ProviderPayout) error
}

// ProviderEarning records a single earning event for a specific provider node.
// This enables per-node earnings tracking (as opposed to account-level balance).
type ProviderEarning struct {
	ID               int64     `json:"id"`
	AccountID        string    `json:"account_id"`
	ProviderID       string    `json:"provider_id"`
	ProviderKey      string    `json:"provider_key"` // X25519 public key (stable hardware ID)
	JobID            string    `json:"job_id"`
	Model            string    `json:"model"`
	AmountMicroUSD   int64     `json:"amount_micro_usd"`
	PromptTokens     int       `json:"prompt_tokens"`
	CompletionTokens int       `json:"completion_tokens"`
	CreatedAt        time.Time `json:"created_at"`
}

// ProviderEarningsSummary captures lifetime payout aggregates independent of
// any pagination applied to recent earnings history.
type ProviderEarningsSummary struct {
	Count            int64 `json:"count"`
	TotalMicroUSD    int64 `json:"total_micro_usd"`
	PromptTokens     int64 `json:"prompt_tokens"`
	CompletionTokens int64 `json:"completion_tokens"`
}

// ProviderPayout records a provider payout event. This is separate from
// account-linked provider earnings because some providers are paid directly
// without being linked to a Privy account.
type ProviderPayout struct {
	ID              int64     `json:"id"`
	ProviderAddress string    `json:"provider_address"`
	AmountMicroUSD  int64     `json:"amount_micro_usd"`
	Model           string    `json:"model"`
	JobID           string    `json:"job_id"`
	Timestamp       time.Time `json:"timestamp"`
	Settled         bool      `json:"settled"`
}
