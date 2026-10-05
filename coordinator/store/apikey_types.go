package store

import "time"

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

	// SelfRouteOnly is a hard ceiling: every request on this key is routed
	// only to a machine the owning account runs, and is free. The key can
	// never spend balance or reach the public fleet. See the "self-route"
	// design in the consumer handler.
	SelfRouteOnly bool `json:"self_route_only"`

	ExpiresAt  *time.Time `json:"expires_at,omitempty"`
	CreatedAt  time.Time  `json:"created_at"`
	LastUsedAt *time.Time `json:"last_used_at,omitempty"`

	// DeletedAt marks a soft-deleted key; no read returns it.
	DeletedAt *time.Time `json:"-"`
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
