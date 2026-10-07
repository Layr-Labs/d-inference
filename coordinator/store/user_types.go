package store

import "time"

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
	StripeAccountCountry   string `json:"stripe_account_country,omitempty"`  // ISO 3166-1 alpha-2 country the Express account is locked to
	StripeDestinationType  string `json:"stripe_destination_type,omitempty"` // "bank" | "card" | ""
	StripeDestinationLast4 string `json:"stripe_destination_last4,omitempty"`
	StripeInstantEligible  bool   `json:"stripe_instant_eligible,omitempty"` // debit-card destination supports Instant Payouts

	// DeletedAt marks a soft-deleted user; no read returns it.
	DeletedAt *time.Time `json:"-"`
}
