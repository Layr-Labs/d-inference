package statsview

// Privacy floor constants: aggregated location buckets with fewer entries
// than these thresholds are suppressed from public stats to prevent
// de-anonymization of individual providers or consumers.
const (
	MinProvidersPerCityBucket = 2
	MinRequestsPerCityBucket  = 5
	minRequestsPerFlowBucket  = 5
)

// publicProviderLocationBucket is the privacy-safe shape returned to
// callers in the provider_locations array.
type ProviderLocationBucket struct {
	Key              string                   `json:"key"`
	Scope            string                   `json:"scope"`
	City             string                   `json:"city,omitempty"`
	Region           string                   `json:"region,omitempty"`
	RegionCode       string                   `json:"region_code,omitempty"`
	Country          string                   `json:"country,omitempty"`
	CountryCode      string                   `json:"country_code,omitempty"`
	Latitude         float64                  `json:"latitude,omitempty"`
	Longitude        float64                  `json:"longitude,omitempty"`
	Providers        int                      `json:"providers"`
	HardwareAttested int                      `json:"hardware_attested"`
	Verification     VerificationMethodCounts `json:"verification_counts"`
	GPUCores         int                      `json:"gpu_cores"`
	MemoryGB         int                      `json:"memory_gb"`
	Models           []string                 `json:"models,omitempty"`
}

// publicRequestLocationBucket is the privacy-safe shape returned for
// request-origin location aggregation.
type RequestLocationBucket struct {
	Key              string  `json:"key"`
	Scope            string  `json:"scope"`
	City             string  `json:"city,omitempty"`
	Region           string  `json:"region,omitempty"`
	RegionCode       string  `json:"region_code,omitempty"`
	Country          string  `json:"country,omitempty"`
	CountryCode      string  `json:"country_code,omitempty"`
	Latitude         float64 `json:"latitude,omitempty"`
	Longitude        float64 `json:"longitude,omitempty"`
	Requests         int64   `json:"requests"`
	PromptTokens     int64   `json:"prompt_tokens"`
	CompletionTokens int64   `json:"completion_tokens"`
	Providers        int     `json:"providers"`
}

// publicRequestFlowBucket represents a directional flow of requests
// between a consumer region and a provider region.
type RequestFlowBucket struct {
	Key              string       `json:"key"`
	From             flowEndpoint `json:"from"`
	To               flowEndpoint `json:"to"`
	Requests         int64        `json:"requests"`
	PromptTokens     int64        `json:"prompt_tokens"`
	CompletionTokens int64        `json:"completion_tokens"`
}

type flowEndpoint struct {
	Key         string  `json:"key"`
	Kind        string  `json:"kind"` // "consumer" or "provider"
	City        string  `json:"city,omitempty"`
	Region      string  `json:"region,omitempty"`
	RegionCode  string  `json:"region_code,omitempty"`
	Country     string  `json:"country,omitempty"`
	CountryCode string  `json:"country_code,omitempty"`
	Latitude    float64 `json:"latitude,omitempty"`
	Longitude   float64 `json:"longitude,omitempty"`
}
