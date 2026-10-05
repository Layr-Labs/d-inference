package store

import "time"

// UsageRecord captures a single inference usage event. On write (RecordUsage)
// ConsumerKey is the raw consumer key; the Postgres store persists only its
// hash and returns that hash as ConsumerKey on read. Timestamp and CreatedAt
// are assigned by the store.
type UsageRecord struct {
	ProviderID  string `json:"provider_id"`
	ConsumerKey string `json:"consumer_key"`
	KeyID       string `json:"key_id,omitempty"`
	Model       string `json:"model"`
	PublicModel string `json:"public_model,omitempty"`
	// PromptTokens counts every prompt token; CachedTokens is the subset the
	// provider served from its prefix cache and billed at the cache-read rate.
	PromptTokens     int               `json:"prompt_tokens"`
	CachedTokens     int               `json:"cached_tokens,omitempty"`
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
