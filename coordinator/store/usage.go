package store

import "time"

// UsageStore covers inference usage recording, settled payments, and the usage
// analytics/aggregation queries (totals, time series, location/flow buckets,
// leaderboard, network totals).
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

	// RecordPayment records a settled payment between consumer and provider.
	RecordPayment(txHash, consumerAddr, providerAddr, amountUSD, model string, promptTokens, completionTokens int, memo string) error

	// UsageRecords returns all usage records.
	UsageRecords() []UsageRecord

	// UsageRecordsSince returns usage records created at or after the given time.
	// Zero since returns all records.
	UsageRecordsSince(since time.Time) []UsageRecord

	// UsageCountSince returns the number of usage records created at or after
	// the given time. Zero since returns all records. Uses SQL COUNT(*) to
	// avoid transferring rows over the wire.
	UsageCountSince(since time.Time) int64

	// UsageTotals returns aggregated lifetime totals across all usage records
	// without transferring per-row data over the wire.
	UsageTotals() UsageTotals

	// UsageTimeSeries returns per-minute aggregates for the given time window.
	// Buckets the rows by created_at truncated to the minute.
	UsageTimeSeries(since time.Time) []UsageBucket

	// UsageLocationBuckets returns approximate request-origin aggregates for
	// public stats. Implementations must not store or return raw client IPs.
	UsageLocationBuckets(since time.Time) []UsageLocationBucket

	// UsageFlowBuckets returns aggregated directional flow buckets between
	// consumer and provider regions. providerLocs supplies live provider
	// locations from the registry so recently-connected providers that
	// haven't been persisted yet are included. PostgresStore uses a SQL
	// JOIN with the providers table and merges the live map; MemoryStore
	// uses providerLocs directly.
	UsageFlowBuckets(since time.Time, providerLocs map[string]*ProviderLocation) []UsageFlowBucket

	// Leaderboard returns the top N accounts ranked by the given metric
	// over the given time window. Zero `since` means all-time.
	Leaderboard(metric LeaderboardMetric, since time.Time, limit int) []LeaderboardRow

	// NetworkTotals returns aggregated metrics across the network for the
	// given window. Zero `since` means all-time.
	NetworkTotals(since time.Time) NetworkTotalsRow

	// UsageByConsumer returns usage records for a specific consumer key.
	UsageByConsumer(consumerKey string) []UsageRecord
}

// UsageRecord captures a single inference usage event.
type UsageRecord struct {
	ProviderID       string            `json:"provider_id"`
	ConsumerKey      string            `json:"consumer_key"`
	KeyID            string            `json:"key_id,omitempty"`
	Model            string            `json:"model"`
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

// UsageBucket is a per-minute aggregation of usage rows.
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

// NormalizeLeaderboardLimit clamps a requested leaderboard page size to the
// supported range, defaulting out-of-range values (<=0 or >200) to 50. Both
// store backends share it so the cap and default live in one place.
func NormalizeLeaderboardLimit(limit int) int {
	if limit <= 0 || limit > 200 {
		return 50
	}
	return limit
}

// LeaderboardRow is a single account's aggregate across provider_earnings.
// Pseudonyms are computed at the API layer from AccountID, never returned
// from the store directly.
type LeaderboardRow struct {
	AccountID        string `json:"account_id"`
	EarningsMicroUSD int64  `json:"earnings_micro_usd"`
	Tokens           int64  `json:"tokens"`
	Jobs             int64  `json:"jobs"`
}

// NetworkTotalsRow holds aggregated network metrics for homepage stats.
type NetworkTotalsRow struct {
	EarningsMicroUSD int64 `json:"earnings_micro_usd"`
	Tokens           int64 `json:"tokens"`
	Jobs             int64 `json:"jobs"`
	ActiveAccounts   int64 `json:"active_accounts"`
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
