package store

import (
	"encoding/json"
	"time"
)

// TelemetryEventRecord is the persistence-layer representation of a telemetry
// event. It mirrors protocol.TelemetryEvent but lives in this package so the
// store can stay free of protocol-layer dependencies.
type TelemetryEventRecord struct {
	ID         string          `json:"id"`
	Timestamp  time.Time       `json:"timestamp"`
	Source     string          `json:"source"`
	Severity   string          `json:"severity"`
	Kind       string          `json:"kind"`
	Version    string          `json:"version,omitempty"`
	MachineID  string          `json:"machine_id,omitempty"`
	AccountID  string          `json:"account_id,omitempty"`
	RequestID  string          `json:"request_id,omitempty"`
	SessionID  string          `json:"session_id,omitempty"`
	Message    string          `json:"message"`
	Fields     json.RawMessage `json:"fields,omitempty"`
	Stack      string          `json:"stack,omitempty"`
	ReceivedAt time.Time       `json:"received_at"`
}

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
