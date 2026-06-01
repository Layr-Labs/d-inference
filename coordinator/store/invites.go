package store

import "time"

// InviteStore covers credit-granting invite codes and their redemptions.
type InviteStore interface {
	// CreateInviteCode stores a new invite code.
	CreateInviteCode(code *InviteCode) error

	// GetInviteCode returns an invite code by its code string.
	GetInviteCode(code string) (*InviteCode, error)

	// ListInviteCodes returns all invite codes (admin view).
	ListInviteCodes() []InviteCode

	// DeactivateInviteCode sets active=false on an invite code.
	DeactivateInviteCode(code string) error

	// RedeemInviteCode atomically increments used_count and records the redemption.
	// Returns error if code is inactive, expired, fully used, or already redeemed by this account.
	RedeemInviteCode(code string, accountID string) error

	// HasRedeemedInviteCode checks if an account has already redeemed a specific code.
	HasRedeemedInviteCode(code, accountID string) bool
}

// InviteCode represents a coordinator-generated invite code that grants credits.
type InviteCode struct {
	Code           string     `json:"code"`
	AmountMicroUSD int64      `json:"amount_micro_usd"`
	MaxUses        int        `json:"max_uses"` // 0 = unlimited
	UsedCount      int        `json:"used_count"`
	Active         bool       `json:"active"`
	CreatedAt      time.Time  `json:"created_at"`
	ExpiresAt      *time.Time `json:"expires_at,omitempty"`
}

// InviteRedemption records a single redemption of an invite code.
type InviteRedemption struct {
	Code      string    `json:"code"`
	AccountID string    `json:"account_id"`
	CreatedAt time.Time `json:"created_at"`
}
