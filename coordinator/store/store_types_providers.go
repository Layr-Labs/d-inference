package store

import (
	"encoding/json"
	"time"
)

// ProviderRecord is the persistent representation of a provider for storage.
// Transient fields (WebSocket conn, pending requests, system metrics) are NOT persisted.
type ProviderRecord struct {
	ID                         string            `json:"id"`
	Hardware                   json.RawMessage   `json:"hardware"`
	Models                     json.RawMessage   `json:"models"`
	Backend                    string            `json:"backend"`
	Location                   *ProviderLocation `json:"location,omitempty"`
	TrustLevel                 string            `json:"trust_level"`
	Attested                   bool              `json:"attested"`
	AttestationResult          json.RawMessage   `json:"attestation_result,omitempty"`
	SEPublicKey                string            `json:"se_public_key,omitempty"`
	PublicKey                  string            `json:"public_key,omitempty"`
	SerialNumber               string            `json:"serial_number,omitempty"`
	MDAVerified                bool              `json:"mda_verified"`
	MDACertChain               json.RawMessage   `json:"mda_cert_chain,omitempty"`
	ACMEVerified               bool              `json:"acme_verified"`
	Version                    string            `json:"version,omitempty"`
	RuntimeVerified            bool              `json:"runtime_verified"`
	PythonHash                 string            `json:"python_hash,omitempty"`
	RuntimeHash                string            `json:"runtime_hash,omitempty"`
	LastChallengeVerified      *time.Time        `json:"last_challenge_verified,omitempty"`
	FailedChallenges           int               `json:"failed_challenges"`
	AccountID                  string            `json:"account_id,omitempty"`
	LifetimeRequestsServed     int64             `json:"lifetime_requests_served"`
	LifetimeTokensGenerated    int64             `json:"lifetime_tokens_generated"`
	LastSessionRequestsServed  int64             `json:"last_session_requests_served"`
	LastSessionTokensGenerated int64             `json:"last_session_tokens_generated"`
	RegisteredAt               time.Time         `json:"registered_at"`
	LastSeen                   time.Time         `json:"last_seen"`
}

// ProviderSession is one connect→disconnect lifecycle of a provider machine.
// connected_at/disconnected_at bound the session; last_seen is the most recent
// heartbeat within it. disconnected_at == nil means the session is still open.
// These rows are the durable source for uptime/downtime history (the providers
// table only keeps a single mutable last_seen).
type ProviderSession struct {
	ID               int64      `json:"id"`
	SessionID        string     `json:"session_id"` // providers.id for this connection
	SerialNumber     string     `json:"serial_number"`
	AccountID        string     `json:"account_id"`
	ConnectedAt      time.Time  `json:"connected_at"`
	LastSeen         time.Time  `json:"last_seen"`
	DisconnectedAt   *time.Time `json:"disconnected_at,omitempty"`
	DisconnectReason string     `json:"disconnect_reason"`
}

// ProviderLocation captures approximate geographic location for a provider or
// request origin. Raw IP addresses are never stored. Populated from GeoIP
// database lookups or trusted reverse-proxy headers.
type ProviderLocation struct {
	City             string    `json:"city,omitempty"`
	Region           string    `json:"region,omitempty"`
	RegionCode       string    `json:"region_code,omitempty"`
	Country          string    `json:"country,omitempty"`
	CountryCode      string    `json:"country_code,omitempty"`
	Latitude         float64   `json:"latitude,omitempty"`
	Longitude        float64   `json:"longitude,omitempty"`
	AccuracyRadiusKM int       `json:"accuracy_radius_km,omitempty"`
	Timezone         string    `json:"timezone,omitempty"`
	Source           string    `json:"source,omitempty"`
	UpdatedAt        time.Time `json:"updated_at,omitempty"`
}

// LogReport represents a stored provider log report. LogData is only populated
// when fetching a single report by ID (GetLogReport), not when listing.
type LogReport struct {
	ID           int64     `json:"id"`
	SerialNumber string    `json:"serial_number"`
	ProviderID   string    `json:"provider_id"`
	AccountID    string    `json:"account_id"`
	LogSizeBytes int64     `json:"log_size_bytes"`
	CreatedAt    time.Time `json:"created_at"`
	LogData      []byte    `json:"log_data,omitempty"`
}

// ReputationRecord is the persistent representation of a provider's reputation.
type ReputationRecord struct {
	TotalJobs          int   `json:"total_jobs"`
	SuccessfulJobs     int   `json:"successful_jobs"`
	FailedJobs         int   `json:"failed_jobs"`
	TotalUptimeSeconds int64 `json:"total_uptime_seconds"`
	AvgResponseTimeMs  int64 `json:"avg_response_time_ms"`
	ChallengesPassed   int   `json:"challenges_passed"`
	ChallengesFailed   int   `json:"challenges_failed"`
}
