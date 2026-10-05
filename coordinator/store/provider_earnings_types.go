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

// ProviderFloorDraw is one epoch's base-reward settlement for one machine.
// Idempotent on (ProviderKey, EpochID). AmountMicroUSD is the new money printed
// (max(0, floor − k·earned)); the audit columns record how it was derived.
type ProviderFloorDraw struct {
	ID             int64     `json:"id"`
	ProviderKey    string    `json:"provider_key"`
	AccountID      string    `json:"account_id"`
	EpochID        string    `json:"epoch_id"` // "YYYY-MM" UTC
	AmountMicroUSD int64     `json:"amount_micro_usd"`
	FloorMicroUSD  int64     `json:"floor_micro_usd"`  // scaled floor used
	EarnedMicroUSD int64     `json:"earned_micro_usd"` // organic earned snapshot
	UptimeFrac     float64   `json:"uptime_frac"`
	MemoryGB       int       `json:"memory_gb"` // verified tier
	CreatedAt      time.Time `json:"created_at"`
}

// ProviderEarningsSummary captures lifetime payout aggregates independent of
// any pagination applied to recent earnings history.
type ProviderEarningsSummary struct {
	Count            int64 `json:"count"`
	TotalMicroUSD    int64 `json:"total_micro_usd"`
	PromptTokens     int64 `json:"prompt_tokens"`
	CompletionTokens int64 `json:"completion_tokens"`
	// BaseRewardMicroUSD is the part of TotalMicroUSD that came from base
	// rewards (model 'base_reward'); inference work is the remainder.
	BaseRewardMicroUSD int64 `json:"base_reward_micro_usd"`
}

// AccountEarningsWindows holds an account's rolling-window earnings (job count
// and micro-USD sum over the last 24 h and the last 7 d) as computed by the
// store, so the dashboard header never sums a truncated row page. Jobs count
// inference rows only (base_reward rows excluded, matching the lifetime
// count); the micro-USD sums include base_reward rows.
type AccountEarningsWindows struct {
	Last24hMicroUSD int64 `json:"last_24h_micro_usd"`
	Last24hJobs     int64 `json:"last_24h_jobs"`
	Last7dMicroUSD  int64 `json:"last_7d_micro_usd"`
	Last7dJobs      int64 `json:"last_7d_jobs"`
}
