package contracts

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"time"
)

// KeyPrefix is the brand prefix for every consumer API key minted by the
// coordinator. The legacy prefix was "eigeninference-"; existing keys with that
// prefix remain valid (lookups are by hash, not prefix) — only newly minted
// keys carry this prefix.
const KeyPrefix = "sk-db-"

// keyRandomBytes is the number of random bytes in the secret portion of a key.
const keyRandomBytes = 32

// GenerateRawKey returns a fresh cryptographically random raw API key of the
// form "sk-db-<64 hex chars>". The raw key is only ever available at creation;
// stores persist a hash, never the plaintext.
func GenerateRawKey() (string, error) {
	b := make([]byte, keyRandomBytes)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return KeyPrefix + hex.EncodeToString(b), nil
}

// GenerateKeyID returns a stable, non-secret public identifier for a key,
// of the form "key_<24 hex chars>". Used for management endpoints and per-key
// usage/spend attribution.
func GenerateKeyID() (string, error) {
	b := make([]byte, 12)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return "key_" + hex.EncodeToString(b), nil
}

// LegacyAccountID derives a stable, NON-SECRET account identity for an unlinked
// legacy API key (one with no owner account). Hashing the raw key keeps the
// secret out of ledger references, balances.account_id, and logs while still
// giving the key a consistent identity across requests. The "legacy:" prefix
// namespaces it so it can never collide with a real Privy account ID.
func LegacyAccountID(rawKey string) string {
	h := sha256.Sum256([]byte(rawKey))
	return "legacy:" + hex.EncodeToString(h[:])
}

// KeyLabel returns a masked display label for a raw key showing the brand
// prefix, the first few characters, and the last four — e.g.
// "sk-db-1a2b…c3d4". Safe to store and show; reveals nothing usable.
func KeyLabel(raw string) string {
	const head = len(KeyPrefix) + 4 // brand prefix + 4 chars of entropy
	if len(raw) <= head+4 {
		// Too short to mask meaningfully; fall back to a head-only prefix.
		if len(raw) <= 6 {
			return raw
		}
		return raw[:6] + "..."
	}
	return raw[:head] + "..." + raw[len(raw)-4:]
}

// NormalizeResetWindow returns a valid reset-window value, defaulting unknown
// or empty inputs to KeyResetNone (a lifetime cap).
func NormalizeResetWindow(reset string) string {
	switch reset {
	case KeyResetDaily, KeyResetWeekly, KeyResetMonthly:
		return reset
	default:
		return KeyResetNone
	}
}

// KeySpendWindowStart returns the UTC instant at which the current spend window
// for the given reset cadence began. For KeyResetNone (lifetime) it returns the
// zero time, meaning "sum all spend". Daily/weekly/monthly align to UTC
// calendar boundaries (midnight UTC; weeks start Monday; months on the 1st).
func KeySpendWindowStart(reset string, now time.Time) time.Time {
	now = now.UTC()
	switch reset {
	case KeyResetDaily:
		return time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	case KeyResetWeekly:
		// Monday is the start of the week. Go's Weekday() has Sunday=0.
		offset := (int(now.Weekday()) + 6) % 7 // days since Monday
		monday := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
		return monday.AddDate(0, 0, -offset)
	case KeyResetMonthly:
		return time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)
	default:
		return time.Time{}
	}
}

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

	// SelfRouteOnly is a hard ceiling: every request on this key is routed
	// only to a machine the owning account runs, and is free. The key can
	// never spend balance or reach the public fleet. See the "self-route"
	// design in the consumer handler.
	SelfRouteOnly bool `json:"self_route_only"`

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
	SelfRouteOnly bool
	ExpiresAt     *time.Time
}

// Account role values. The empty string is a normal consumer account.
const (
	// RoleService marks a trusted machine/partner account (e.g. an upstream
	// aggregator such as OpenRouter). Service accounts get elevated or
	// bypassed rate limits. They authenticate with a normal API key whose
	// linked user carries this role.
	RoleService = "service"
)

// APIKeyStore covers consumer API-key lifecycle: the legacy single-key helpers,
// multi-key management (one account → many named, limited keys), and key counts.
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

// hashKey returns the SHA-256 hex digest of the given API key.
func hashKey(key string) string {
	h := sha256.Sum256([]byte(key))
	return hex.EncodeToString(h[:])
}

// HashKey returns the SHA-256 hex digest of the given API key.
func HashKey(key string) string { return hashKey(key) }
