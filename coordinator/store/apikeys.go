package store

import "time"

// APIKeyStore covers consumer API keys: the legacy single-key helpers and the
// multi-key management surface (one account → many named, limited keys).
type APIKeyStore interface {
	// CreateKey generates a new API key, persists it, and returns it.
	CreateKey() (string, error)

	// CreateKeyForAccount generates a new API key linked to a specific account.
	CreateKeyForAccount(accountID string) (string, error)

	// ValidateKey returns true if the given key exists and is active.
	ValidateKey(key string) bool

	// GetKeyAccount returns the account ID that owns this key, or "" if unlinked.
	GetKeyAccount(key string) string

	// ValidateKeyFull returns the active status and owner account ID for an
	// API key in a single query, avoiding the 2-query overhead of
	// ValidateKey + GetKeyAccount on every authenticated request.
	ValidateKeyFull(key string) (active bool, ownerAccountID string, err error)

	// RevokeKey deactivates a key. Returns true if the key existed.
	RevokeKey(key string) bool

	// --- Multi-key management (one account → many named, limited keys) ---

	// CreateAPIKey mints a new API key for an account with optional per-key
	// limits. It returns the raw key (shown once) and the stored record.
	CreateAPIKey(accountID string, opts APIKeyCreate) (rawKey string, key *APIKey, err error)

	// ListAPIKeys returns all (non-deleted) keys owned by an account, newest
	// first. Secrets are never returned — only the masked label + metadata.
	ListAPIKeys(accountID string) ([]APIKey, error)

	// GetAPIKeyByID returns a single key by its public ID, scoped to the owner.
	GetAPIKeyByID(accountID, id string) (*APIKey, error)

	// UpdateAPIKey overwrites the mutable fields (name, disabled, limits,
	// reset window, expiry, model allow-list) of a key, scoped to the owner.
	// The caller supplies the fully-merged desired state; nil pointers clear
	// the corresponding limit.
	UpdateAPIKey(accountID, id string, mutable APIKey) (*APIKey, error)

	// RevokeAPIKeyByID permanently deletes a key by ID, scoped to the owner.
	RevokeAPIKeyByID(accountID, id string) error

	// RotateAPIKey atomically replaces a key: it mints a new secret carrying the
	// old key's name, limits, expiry, and disabled state, deletes the old key,
	// and returns the new raw secret + record — all in one transaction/critical
	// section so the old key is never usable after success and a concurrent
	// rotate of the same key cannot mint two replacements. Scoped to the owner.
	RotateAPIKey(accountID, id string) (rawKey string, key *APIKey, err error)

	// AuthenticateKey resolves a raw key to its active record for request
	// authentication. It returns an error when the key is unknown, disabled,
	// or expired. The returned record carries the owner account and per-key
	// limits used by the request path.
	AuthenticateKey(rawKey string) (*APIKey, error)

	// TouchAPIKey records that a key was used at the given time (last_used_at).
	// Best-effort; callers typically invoke it asynchronously and throttled.
	TouchAPIKey(id string, at time.Time)

	// KeySpendSince returns the total micro-USD charged to the given key ID
	// since the given UTC time. Zero `since` returns lifetime spend. Used to
	// enforce per-key spend caps before the ledger reservation.
	KeySpendSince(keyID string, since time.Time) int64

	// KeyCount returns the number of active API keys.
	KeyCount() int
}

// Per-key spend-cap reset windows. A cap with KeyResetNone is a lifetime cap;
// the others reset at the corresponding UTC calendar boundary (midnight UTC for
// daily, Monday 00:00 UTC for weekly, the 1st 00:00 UTC for monthly).
const (
	KeyResetNone    = "none"
	KeyResetDaily   = "daily"
	KeyResetWeekly  = "weekly"
	KeyResetMonthly = "monthly"
)

// APIKey is a consumer API key with optional per-key limits. One account may
// own many keys. The account's prepaid balance is always the hard ceiling;
// each key's limits are sub-caps enforced before the ledger reservation.
//
// Nil limit pointers mean "no per-key limit" for that dimension (the key is
// bounded only by the account's balance and the global per-account limiters).
type APIKey struct {
	ID             string `json:"id"`               // stable public id (e.g. "key_…"); safe to expose
	OwnerAccountID string `json:"owner_account_id"` // owning account
	Name           string `json:"name"`             // user-set label
	Label          string `json:"label"`            // masked prefix…suffix for display (e.g. "sk-db-1a2b…c3d4")
	KeyHash        string `json:"-"`                // sha256 of the raw key (Postgres); never serialized

	Disabled bool `json:"disabled"` // soft lifecycle — a disabled key fails auth fast

	// Spend cap. LimitMicroUSD nil = unlimited. LimitReset selects the window.
	LimitMicroUSD *int64 `json:"limit_micro_usd,omitempty"`
	LimitReset    string `json:"limit_reset"` // none | daily | weekly | monthly

	// Throughput overrides. Nil = inherit the account-level limiter.
	RPMLimit  *int64 `json:"rpm_limit,omitempty"`  // requests per minute
	ITPMLimit *int64 `json:"itpm_limit,omitempty"` // input tokens per minute
	OTPMLimit *int64 `json:"otpm_limit,omitempty"` // output tokens per minute

	// AllowedModels restricts which models the key may call. Empty = all.
	AllowedModels []string `json:"allowed_models,omitempty"`

	ExpiresAt  *time.Time `json:"expires_at,omitempty"`
	CreatedAt  time.Time  `json:"created_at"`
	LastUsedAt *time.Time `json:"last_used_at,omitempty"`
}

// APIKeyCreate carries the create-time options for a new API key. All limit
// fields are optional; a nil pointer means "no limit" for that dimension.
type APIKeyCreate struct {
	Name          string
	LimitMicroUSD *int64
	LimitReset    string
	RPMLimit      *int64
	ITPMLimit     *int64
	OTPMLimit     *int64
	AllowedModels []string
	ExpiresAt     *time.Time
}
