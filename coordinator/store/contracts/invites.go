package contracts

import (
	"errors"
	"time"
)

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

// InviteStore manages coordinator-generated invite codes and their redemptions.
type InviteStore interface {
	// CreateInviteCode stores a new invite code.
	CreateInviteCode(code *InviteCode) error

	// GetInviteCode returns an invite code by its code string.
	GetInviteCode(code string) (*InviteCode, error)

	// ListInviteCodes returns all invite codes (admin view).
	ListInviteCodes() []InviteCode

	// DeactivateInviteCode sets active=false on an invite code.
	DeactivateInviteCode(code string) error

	// RedeemInviteCode atomically increments used_count, records the redemption,
	// and credits the invite amount to the non-withdrawable balance and ledger.
	// A credit failure returns ErrInviteCredit and leaves no claim or use count.
	// Returns error if code is inactive, expired, fully used, or already redeemed by this account.
	RedeemInviteCode(code string, accountID string) error

	// HasRedeemedInviteCode checks if an account has already redeemed a specific code.
	HasRedeemedInviteCode(code, accountID string) bool
}

// ErrInviteCredit identifies a balance or ledger write failure during invite
// redemption. The store rolls back the claim so the same invite can be retried.
var ErrInviteCredit = errors.New("invite credit failed")
