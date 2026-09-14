package contracts

import (
	"context"
	"encoding/json"
	"time"
)

// ProviderRecord is the persistent representation of a provider for storage.
// Transient fields (WebSocket conn, pending requests, system metrics) are NOT persisted.
type ProviderRecord struct {
	ID                string            `json:"id"`
	Hardware          json.RawMessage   `json:"hardware"`
	Models            json.RawMessage   `json:"models"`
	Backend           string            `json:"backend"`
	Location          *ProviderLocation `json:"location,omitempty"`
	TrustLevel        string            `json:"trust_level"`
	Attested          bool              `json:"attested"`
	AttestationResult json.RawMessage   `json:"attestation_result,omitempty"`
	SEPublicKey       string            `json:"se_public_key,omitempty"`
	// PublicKey is the machine's X25519 E2E public key (non-secret — published
	// at /v1/encryption-key), persisted so an offline machine's key is still
	// available without a live connection.
	PublicKey                  string          `json:"public_key,omitempty"`
	SerialNumber               string          `json:"serial_number,omitempty"`
	MDAVerified                bool            `json:"mda_verified"`
	MDACertChain               json.RawMessage `json:"mda_cert_chain,omitempty"`
	Version                    string          `json:"version,omitempty"`
	RuntimeVerified            bool            `json:"runtime_verified"`
	PythonHash                 string          `json:"python_hash,omitempty"`
	RuntimeHash                string          `json:"runtime_hash,omitempty"`
	LastChallengeVerified      *time.Time      `json:"last_challenge_verified,omitempty"`
	FailedChallenges           int             `json:"failed_challenges"`
	AccountID                  string          `json:"account_id,omitempty"`
	LifetimeRequestsServed     int64           `json:"lifetime_requests_served"`
	LifetimeTokensGenerated    int64           `json:"lifetime_tokens_generated"`
	LastSessionRequestsServed  int64           `json:"last_session_requests_served"`
	LastSessionTokensGenerated int64           `json:"last_session_tokens_generated"`
	LifetimeStats              json.RawMessage `json:"lifetime_stats,omitempty"`
	LastSessionStats           json.RawMessage `json:"last_session_stats,omitempty"`
	RegisteredAt               time.Time       `json:"registered_at"`
	LastSeen                   time.Time       `json:"last_seen"`
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

// ProviderStore persists the provider fleet (records + connect/disconnect
// sessions), reputation, the APNs code-identity and live-MDM trust-reuse caches
// (durable across deploys), and provider log reports.
type ProviderStore interface {
	ProviderRecordStore
	ProviderSessionStore
	ReputationStore
	CodeAttestationStore
	TrustReuseStore
	VerificationStore
	LogReportStore
}

// ProviderRecordStore reads and atomically updates persisted fleet records.
type ProviderRecordStore interface {
	// --- Provider Fleet Persistence ---

	// UpsertProvider creates or updates a provider record.
	UpsertProvider(ctx context.Context, p ProviderRecord) error

	// UpsertProviderWithReputation atomically publishes a completed provider record
	// with the reputation that the next reconnect will read.
	UpsertProviderWithReputation(ctx context.Context, p ProviderRecord, rep ReputationRecord) error

	// GetProviderRecord returns a provider record by ID.
	GetProviderRecord(ctx context.Context, id string) (*ProviderRecord, error)

	// GetProviderBySerial returns a provider record by serial number.
	GetProviderBySerial(ctx context.Context, serial string) (*ProviderRecord, error)

	// GetProviderForRestore returns the newest historical record for a verified
	// serial, falling back to the verified SE key only when no serial record exists.
	// excludeIDs removes all live/in-progress sessions from the candidate set. No match returns (nil, nil); failures return errors.
	GetProviderForRestore(ctx context.Context, serial, seKey string, excludeIDs []string) (*ProviderRecord, error)

	// GetMDAChainBySerial returns the newest NON-EMPTY Apple MDA cert chain stored
	// for a serial, or (nil, nil) if none. A reconnecting provider gets a new row
	// (keyed by a fresh provider id) that may be persisted with an empty chain
	// before the chain is reattached; GetProviderBySerial would return that newer
	// empty row and shadow a still-valid chain from a prior connection. This query
	// looks past empty rows so MDA reuse survives that race.
	GetMDAChainBySerial(ctx context.Context, serial string) (json.RawMessage, error)

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

	// DeleteProvidersBySerial removes every persisted provider record sharing the
	// given stable identity (serial, or a session id when serial is empty),
	// scoped to ownerAccountID, plus their provider_reputation rows. usage,
	// provider_earnings and provider_sessions (billing/uptime history) are
	// preserved. Returns the number of provider rows removed.
	DeleteProvidersBySerial(ctx context.Context, ownerAccountID, serialOrID string) (int, error)
}
