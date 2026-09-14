package contracts

import (
	"time"
)

// UsageRecord captures a single inference usage event.
type UsageRecord struct {
	ProviderID       string            `json:"provider_id"`
	ConsumerKey      string            `json:"consumer_key"`
	KeyID            string            `json:"key_id,omitempty"`
	Model            string            `json:"model"`
	PublicModel      string            `json:"public_model,omitempty"`
	PromptTokens     int               `json:"prompt_tokens"`
	CompletionTokens int               `json:"completion_tokens"`
	RequestLocation  *ProviderLocation `json:"request_location,omitempty"`
	Timestamp        time.Time         `json:"timestamp"`
	RequestID        string            `json:"request_id,omitempty"`
	CostMicroUSD     int64             `json:"cost_micro_usd,omitempty"`
	CreatedAt        time.Time         `json:"created_at,omitempty"`
}

// UsageTotals aggregates the entire usage table.
type UsageTotals struct {
	Requests         int64 `json:"requests"`
	PromptTokens     int64 `json:"prompt_tokens"`
	CompletionTokens int64 `json:"completion_tokens"`
}

// UsageBucket is a time-bucketed aggregation of usage rows. Minute is retained
// as the field name for wire compatibility with the original minute series.
type UsageBucket struct {
	Minute           time.Time `json:"minute"`
	Requests         int64     `json:"requests"`
	PromptTokens     int64     `json:"prompt_tokens"`
	CompletionTokens int64     `json:"completion_tokens"`
}

// UsageLocationBucket aggregates request-origin location data for public stats.
type UsageLocationBucket struct {
	City             string  `json:"city"`
	Region           string  `json:"region"`
	RegionCode       string  `json:"region_code"`
	Country          string  `json:"country"`
	CountryCode      string  `json:"country_code"`
	Latitude         float64 `json:"latitude"`
	Longitude        float64 `json:"longitude"`
	Requests         int64   `json:"requests"`
	PromptTokens     int64   `json:"prompt_tokens"`
	CompletionTokens int64   `json:"completion_tokens"`
	Providers        int     `json:"providers"`
}

// UsageFlowBucket is a pre-aggregated directional flow between a consumer
// location and a provider location, computed via SQL JOIN.
type UsageFlowBucket struct {
	// Consumer (request origin)
	ConsumerCity        string  `json:"consumer_city"`
	ConsumerRegion      string  `json:"consumer_region"`
	ConsumerRegionCode  string  `json:"consumer_region_code"`
	ConsumerCountry     string  `json:"consumer_country"`
	ConsumerCountryCode string  `json:"consumer_country_code"`
	ConsumerLatitude    float64 `json:"consumer_latitude"`
	ConsumerLongitude   float64 `json:"consumer_longitude"`
	// Provider
	ProviderCity        string  `json:"provider_city"`
	ProviderRegion      string  `json:"provider_region"`
	ProviderRegionCode  string  `json:"provider_region_code"`
	ProviderCountry     string  `json:"provider_country"`
	ProviderCountryCode string  `json:"provider_country_code"`
	ProviderLatitude    float64 `json:"provider_latitude"`
	ProviderLongitude   float64 `json:"provider_longitude"`
	// Aggregates
	Requests         int64 `json:"requests"`
	PromptTokens     int64 `json:"prompt_tokens"`
	CompletionTokens int64 `json:"completion_tokens"`
}

// LeaderboardMetric selects the ranking column for a leaderboard query.
type LeaderboardMetric string

const (
	LeaderboardEarnings LeaderboardMetric = "earnings"
	LeaderboardTokens   LeaderboardMetric = "tokens"
	LeaderboardJobs     LeaderboardMetric = "jobs"
)

// LeaderboardRow is a single account's aggregate across provider_earnings
// (inference work) combined with reward ledger entries (referral_reward and
// admin_reward). EarningsMicroUSD is the combined total of work + reward.
// Pseudonyms are computed at the API layer from AccountID, never returned
// from the store directly.
type LeaderboardRow struct {
	AccountID              string `json:"account_id"`
	EarningsMicroUSD       int64  `json:"earnings_micro_usd"`        // total = work + reward
	WorkEarningsMicroUSD   int64  `json:"work_earnings_micro_usd"`   // inference payouts
	RewardEarningsMicroUSD int64  `json:"reward_earnings_micro_usd"` // referral_reward + admin_reward
	Tokens                 int64  `json:"tokens"`
	Jobs                   int64  `json:"jobs"`
}

// NetworkTotalsRow holds aggregated network metrics for homepage stats.
type NetworkTotalsRow struct {
	EarningsMicroUSD       int64 `json:"earnings_micro_usd"` // total = work + reward
	WorkEarningsMicroUSD   int64 `json:"work_earnings_micro_usd"`
	RewardEarningsMicroUSD int64 `json:"reward_earnings_micro_usd"`
	Tokens                 int64 `json:"tokens"`
	Jobs                   int64 `json:"jobs"`
	ActiveAccounts         int64 `json:"active_accounts"`
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

// UsageStore records inference usage events and settled payments and serves the
// usage/stats aggregations (totals, time series, geo, leaderboards).
type UsageStore interface {
	// RecordUsage logs an inference usage event.
	RecordUsage(providerID, consumerKey, model string, promptTokens, completionTokens int)

	// RecordUsageWithCost logs an inference usage event including request ID and cost.
	RecordUsageWithCost(providerID, consumerKey, model, requestID string, promptTokens, completionTokens int, costMicroUSD int64)

	// RecordUsageWithCostAndLocation logs an inference usage event with an
	// approximate request-origin location. Raw IP addresses are not stored.
	RecordUsageWithCostAndLocation(providerID, consumerKey, model, requestID string, promptTokens, completionTokens int, costMicroUSD int64, requestLocation *ProviderLocation)

	// RecordUsageFull logs an inference usage event with full attribution
	// including the originating API key ID (for per-key usage and spend
	// tracking). keyID may be empty for legacy/account-scoped attribution.
	RecordUsageFull(providerID, consumerKey, keyID, model, requestID string, promptTokens, completionTokens int, costMicroUSD int64, requestLocation *ProviderLocation)

	// RecordUsageFullWithPublicModel logs the concrete billing/statistics model
	// plus the optional consumer-facing model name returned by usage history.
	RecordUsageFullWithPublicModel(providerID, consumerKey, keyID, model, publicModel, requestID string, promptTokens, completionTokens int, costMicroUSD int64, requestLocation *ProviderLocation)

	// RecordPayment records a settled payment between consumer and provider.
	RecordPayment(txHash, consumerAddr, providerAddr, amountUSD, model string, promptTokens, completionTokens int, memo string) error

	// UsageRecords returns all usage records.
	UsageRecords() []UsageRecord

	// UsageRecordsSince returns usage records created at or after the given time.
	// Zero since returns all records.
	UsageRecordsSince(since time.Time) []UsageRecord

	// UsageCountSince returns the number of usage records created at or after
	// the given time. Zero since returns all records. Uses SQL COUNT(*) to
	// avoid transferring rows over the wire. It returns an error (never a
	// zero count) when the statement could not be completed, so callers do
	// not cache or display zeros for a statement that timed out.
	UsageCountSince(since time.Time) (int64, error)

	// UsageTotals returns aggregated lifetime totals across all usage records
	// without transferring per-row data over the wire. It returns an error
	// (never zero totals) when the statement could not be completed.
	UsageTotals() (UsageTotals, error)

	// UsageTotalsSince returns aggregate usage at or after the given time
	// without transferring per-row data over the wire. It returns an error
	// (never zero totals) when the statement could not be completed.
	UsageTotalsSince(since time.Time) (UsageTotals, error)

	// UsageTimeSeries returns aggregates for the given time window using the
	// requested bucket size. Implementations enforce a one-minute minimum,
	// thirty-day maximum lookback, and bounded result cardinality. It returns
	// an error (never a partial or empty series) when the statement could
	// not be completed.
	UsageTimeSeries(since, until time.Time, bucketSize time.Duration) ([]UsageBucket, error)

	// UsageLocationBuckets returns approximate request-origin aggregates for
	// public stats. Implementations must not store or return raw client IPs.
	// An error distinguishes query failure from a successful empty window.
	UsageLocationBuckets(since time.Time) ([]UsageLocationBucket, error)

	// UsageFlowBuckets returns aggregated directional flow buckets between
	// consumer and provider regions. providerLocs supplies live provider
	// locations from the registry so recently-connected providers that
	// haven't been persisted yet are included. PostgresStore uses a SQL
	// JOIN with the providers table and merges the live map; MemoryStore
	// uses providerLocs directly.
	// Query and iteration failures return an error, never partial buckets.
	UsageFlowBuckets(since time.Time, providerLocs map[string]*ProviderLocation) ([]UsageFlowBucket, error)

	// Leaderboard returns the top N accounts ranked by the given metric
	// over the given time window. Zero `since` means all-time.
	Leaderboard(metric LeaderboardMetric, since time.Time, limit int) []LeaderboardRow

	// NetworkTotals returns aggregated metrics across the network for the
	// given window. Zero `since` means all-time. It returns an error (never a
	// zero row) when the aggregate could not be computed, so callers do not
	// cache or display zeros for a statement that timed out.
	NetworkTotals(since time.Time) (NetworkTotalsRow, error)

	// UsageByConsumer returns usage records for a specific consumer key.
	UsageByConsumer(consumerKey string) []UsageRecord
}
