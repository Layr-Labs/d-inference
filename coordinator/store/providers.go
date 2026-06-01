package store

import (
	"context"
	"encoding/json"
	"time"
)

// ProviderStore covers persistence of the provider fleet: records plus their
// trust, challenge, and runtime-integrity state.
type ProviderStore interface {
	// UpsertProvider creates or updates a provider record.
	UpsertProvider(ctx context.Context, p ProviderRecord) error

	// GetProviderRecord returns a provider record by ID.
	GetProviderRecord(ctx context.Context, id string) (*ProviderRecord, error)

	// GetProviderBySerial returns a provider record by serial number.
	GetProviderBySerial(ctx context.Context, serial string) (*ProviderRecord, error)

	// ListProviderRecords returns all stored provider records.
	ListProviderRecords(ctx context.Context) ([]ProviderRecord, error)

	// ListProvidersByAccount returns stored provider records linked to an account.
	ListProvidersByAccount(ctx context.Context, accountID string) ([]ProviderRecord, error)

	// UpdateProviderLastSeen updates the last_seen timestamp for a provider.
	UpdateProviderLastSeen(ctx context.Context, id string) error

	// UpdateProviderTrust persists trust level and attestation state changes.
	UpdateProviderTrust(ctx context.Context, id string, trustLevel string, attested bool, attestationResult json.RawMessage) error

	// UpdateProviderChallenge persists challenge verification state.
	UpdateProviderChallenge(ctx context.Context, id string, lastVerified time.Time, failedCount int) error

	// UpdateProviderRuntime persists runtime integrity verification state.
	UpdateProviderRuntime(ctx context.Context, id string, verified bool, pythonHash, runtimeHash string) error
}

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
