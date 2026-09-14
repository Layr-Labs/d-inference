package accounts

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// KeyUsage reads settled usage for the existing soft per-key spend cap.
// The account ledger remains the atomic balance ceiling.
type KeyUsage interface{ KeySpendSince(string, time.Time) int64 }

// KeyStore supplies key records, scoped mutations and settled usage.
type KeyStore interface {
	KeyUsage
	CreateKeyForAccount(string) (string, error)
	GetKeyAccount(string) string
	RevokeKey(string) bool
	CreateAPIKey(string, store.APIKeyCreate) (string, *store.APIKey, error)
	ListAPIKeys(string) ([]store.APIKey, error)
	GetAPIKeyByID(string, string) (*store.APIKey, error)
	UpdateAPIKey(string, string, store.APIKey) (*store.APIKey, error)
	RevokeAPIKeyByID(string, string) error
	RotateAPIKey(string, string) (string, *store.APIKey, error)
}

// DeviceStore persists device approvals and issued provider tokens.
type DeviceStore interface {
	CreateDeviceCode(*store.DeviceCode) error
	GetDeviceCode(string) (*store.DeviceCode, error)
	GetDeviceCodeByUserCode(string) (*store.DeviceCode, error)
	ApproveDeviceCode(string, string) error
	CreateProviderToken(*store.ProviderToken) error
}

// InviteStore keeps invite redemption and balance operations in their existing
// persistence implementations; the controller preserves their call ordering.
type InviteStore interface {
	CreateInviteCode(*store.InviteCode) error
	GetInviteCode(string) (*store.InviteCode, error)
	ListInviteCodes() []store.InviteCode
	DeactivateInviteCode(string) error
	RedeemInviteCode(string, string) error
	Credit(string, int64, store.LedgerEntryType, string) error
	GetBalance(string) int64
}

// Store composes only the persistence domains used by account operations.
type Store interface {
	KeyStore
	DeviceStore
	InviteStore
}
