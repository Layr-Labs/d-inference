package contracts

import (
	"time"
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
}

// UserStore manages consumer accounts linked to Privy identities, including
// their Stripe Connect payout fields, role, and platform-fee override.
type UserStore interface {
	// CreateUser creates a new user record linked to a Privy identity.
	CreateUser(user *User) error

	// GetUserByPrivyID returns the user for a Privy DID.
	GetUserByPrivyID(privyUserID string) (*User, error)

	// GetUserByAccountID returns the user for an internal account ID.
	GetUserByAccountID(accountID string) (*User, error)

	// GetUserByEmail returns the user for an email address.
	GetUserByEmail(email string) (*User, error)

	// SetUserStripeAccount upserts the Stripe Connect fields on a user record.
	// Pass empty strings to clear the destination (e.g. before re-onboarding).
	// stripeAccountCountry is the ISO 3166-1 alpha-2 country the Express
	// account is locked to; empty leaves the column unchanged.
	SetUserStripeAccount(accountID, stripeAccountID, status, stripeAccountCountry, destinationType, destinationLast4 string, instantEligible bool) error

	// GetUserByStripeAccount finds a user by their Stripe connected account ID.
	// Used by webhook handlers to route account.updated / payout.* events.
	GetUserByStripeAccount(stripeAccountID string) (*User, error)

	// SetUserRole sets the account role (e.g. "" or RoleService). Used by the
	// admin API to grant a partner account elevated rate limits.
	SetUserRole(accountID, role string) error

	// SetUserPlatformFeePercent sets a per-account platform fee override.
	// Pass nil to clear the override and fall back to the global default.
	// A non-nil value of 0 waives the platform fee entirely.
	SetUserPlatformFeePercent(accountID string, feePercent *int64) error
}
