package store

import "time"

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

// User represents a consumer account linked to a Privy identity.
type User struct {
	AccountID   string    `json:"account_id"`      // internal account ID (used in ledger)
	PrivyUserID string    `json:"privy_user_id"`   // Privy DID (e.g. "did:privy:abc123")
	Email       string    `json:"email,omitempty"` // from Privy linked accounts
	CreatedAt   time.Time `json:"created_at"`

	// Role gates elevated capabilities. "" = normal consumer,
	// RoleService = trusted partner/aggregator (elevated rate limits).
	Role string `json:"role,omitempty"`

	// PlatformFeePercent overrides the global platform routing fee for this
	// account when non-nil. nil = use the global default. A value of 0 means
	// the account pays no platform fee (the provider receives 100%). Used to
	// waive the fee for wholesale partners such as OpenRouter.
	PlatformFeePercent *int64 `json:"platform_fee_percent,omitempty"`

	// Stripe Connect Express — for bank/card payouts via Stripe.
	// StripeAccountStatus mirrors the readiness of payouts on the connected
	// account: "" (not onboarded), "pending" (link created but not finished),
	// "ready" (payouts_enabled=true), "restricted" (Stripe needs more info),
	// "rejected" (Stripe permanently disabled the account).
	StripeAccountID        string `json:"stripe_account_id,omitempty"`
	StripeAccountStatus    string `json:"stripe_account_status,omitempty"`
	StripeDestinationType  string `json:"stripe_destination_type,omitempty"` // "bank" | "card" | ""
	StripeDestinationLast4 string `json:"stripe_destination_last4,omitempty"`
	StripeInstantEligible  bool   `json:"stripe_instant_eligible,omitempty"` // debit-card destination supports Instant Payouts
}

// StripeWithdrawal records a user-initiated payout via Stripe Connect Express.
// The lifecycle is: pending (debit recorded) → transferred (platform→connected
// account transfer succeeded) → paid (Stripe payout to bank/card succeeded).
// On failure at any stage we re-credit the user via LedgerRefund and set the
// status to "failed".
type StripeWithdrawal struct {
	ID              string    `json:"id"`                       // internal UUID, used as Stripe idempotency key prefix
	AccountID       string    `json:"account_id"`               // internal account that owns the withdrawal
	StripeAccountID string    `json:"stripe_account_id"`        // Stripe connected account (acct_…)
	TransferID      string    `json:"transfer_id,omitempty"`    // Stripe transfer (tr_…)
	PayoutID        string    `json:"payout_id,omitempty"`      // Stripe payout (po_…)
	AmountMicroUSD  int64     `json:"amount_micro_usd"`         // gross amount debited from ledger
	FeeMicroUSD     int64     `json:"fee_micro_usd"`            // fee retained by platform
	NetMicroUSD     int64     `json:"net_micro_usd"`            // amount transferred to user (gross - fee)
	Method          string    `json:"method"`                   // "standard" | "instant"
	Status          string    `json:"status"`                   // "pending" | "transferred" | "paid" | "failed"
	FailureReason   string    `json:"failure_reason,omitempty"` // populated when Status="failed"
	Refunded        bool      `json:"refunded,omitempty"`       // true after the failure refund is credited
	CreatedAt       time.Time `json:"created_at"`
	UpdatedAt       time.Time `json:"updated_at"`
}
