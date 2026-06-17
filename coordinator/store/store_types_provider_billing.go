package store

import "time"

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

// BillingSession tracks an in-progress payment via any method (Stripe).
type BillingSession struct {
	ID             string     `json:"id"`
	AccountID      string     `json:"account_id"`
	PaymentMethod  string     `json:"payment_method"` // "stripe"
	AmountMicroUSD int64      `json:"amount_micro_usd"`
	ExternalID     string     `json:"external_id"`   // Stripe session ID, tx hash, etc.
	Status         string     `json:"status"`        // "pending", "completed", "expired"
	ReferralCode   string     `json:"referral_code"` // optional
	CreatedAt      time.Time  `json:"created_at"`
	CompletedAt    *time.Time `json:"completed_at,omitempty"`
}
