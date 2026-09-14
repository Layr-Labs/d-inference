package contracts

import (
	"context"
	"time"
)

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
}

// AccountEarningsWindows holds an account's rolling-window earnings (row count
// and micro-USD sum over the last 24 h and the last 7 d) as computed by the
// store, so the dashboard header never sums a truncated row page.
type AccountEarningsWindows struct {
	Last24hMicroUSD int64 `json:"last_24h_micro_usd"`
	Last24hJobs     int64 `json:"last_24h_jobs"`
	Last7dMicroUSD  int64 `json:"last_7d_micro_usd"`
	Last7dJobs      int64 `json:"last_7d_jobs"`
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

// ProviderEarningsStore tracks per-node provider earnings and payouts plus the
// base-rewards (earnings-floor) settlement machinery.
type ProviderEarningsStore interface {
	// --- Provider Earnings (per-node tracking) ---

	// RecordProviderEarning stores an earning record for a specific provider node.
	RecordProviderEarning(earning *ProviderEarning) error

	// GetProviderEarnings returns earnings for a specific provider node (by public key), newest first.
	GetProviderEarnings(providerKey string, limit int) ([]ProviderEarning, error)

	// GetAccountEarnings returns all earnings across all nodes for an account, newest first.
	GetAccountEarnings(accountID string, limit int) ([]ProviderEarning, error)

	// GetProviderEarningsSummary returns lifetime aggregates for a provider node
	// across ALL accounts that have ever owned the key.
	GetProviderEarningsSummary(providerKey string) (ProviderEarningsSummary, error)

	// GetAccountEarningsSummary returns lifetime aggregates for an account across all linked nodes.
	GetAccountEarningsSummary(accountID string) (ProviderEarningsSummary, error)

	// AccountEarningsWindows returns the account's last-24h and last-7d row
	// count and micro-USD sum as of now, aggregated by the store over the
	// 7 d window only. Every provider_earnings row counts (base_reward rows
	// included), matching the dashboard header's historical semantics.
	AccountEarningsWindows(accountID string, now time.Time) (AccountEarningsWindows, error)

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

	// --- Base Rewards (provider earnings floor) ---

	// SumProviderEarningsByKey returns total organic micro-USD for one provider
	// node in [since, until): amount>0, model != 'base_reward'. Self-route already
	// produces no earning row, so it needs no extra filter.
	SumProviderEarningsByKey(ctx context.Context, providerKey string, since, until time.Time) (int64, error)

	// SettleProviderFloorDraw atomically (1) inserts the idempotent draw row
	// (ON CONFLICT (provider_key, epoch_id) DO NOTHING) and (2) credits the
	// account's balance + withdrawable with a LedgerFloorDraw entry — but ONLY
	// when the row was newly inserted. Returns credited=false on a duplicate
	// epoch. A zero-amount draw still inserts the audit row but credits nothing.
	SettleProviderFloorDraw(ctx context.Context, draw *ProviderFloorDraw) (credited bool, err error)

	// SumFloorDrawsForEpoch returns Σ amount_micro_usd already settled for an
	// epoch (pool-cap accounting + admin status).
	SumFloorDrawsForEpoch(ctx context.Context, epochID string) (int64, error)

	// ListFloorDrawsForEpoch returns all draw rows for an epoch (admin status).
	ListFloorDrawsForEpoch(ctx context.Context, epochID string) ([]ProviderFloorDraw, error)

	// ListProviderSessionsOverlapping returns sessions whose lifetime interval
	// overlaps [start, end). Closed sessions end at disconnected_at; open sessions
	// may overlap via last_seen + openSessionGrace. The caller unions per machine
	// and clamps open sessions to min(end, last_seen + grace). Ordered by
	// serial_number, connected_at.
	ListProviderSessionsOverlapping(ctx context.Context, start, end time.Time, openSessionGrace time.Duration) ([]ProviderSession, error)

	// WithEpochSettlementLock runs fn while holding a cross-instance lock keyed
	// on epochID, so two coordinators cannot settle the same epoch concurrently
	// and overshoot the floor pool cap. The memory store runs fn directly; the
	// postgres store uses a session-level advisory lock.
	WithEpochSettlementLock(ctx context.Context, epochID string, fn func() error) error
}
