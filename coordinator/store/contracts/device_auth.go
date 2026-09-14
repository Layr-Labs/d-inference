package contracts

import (
	"time"
)

// DeviceCode represents a pending device authorization request (RFC 8628-style).
// The provider CLI creates one, displays the UserCode, and polls until approved.
type DeviceCode struct {
	DeviceCode string    `json:"device_code"` // opaque code for polling (secret, sent only to device)
	UserCode   string    `json:"user_code"`   // short human-readable code (e.g. "ABCD-1234")
	AccountID  string    `json:"account_id"`  // set when user approves (empty while pending)
	Status     string    `json:"status"`      // "pending", "approved", "expired"
	ExpiresAt  time.Time `json:"expires_at"`
	CreatedAt  time.Time `json:"created_at"`
}

// ProviderToken is a long-lived auth token linking a provider machine to an account.
// Created when a device code is approved; used by the provider on every WebSocket connect.
type ProviderToken struct {
	TokenHash string    `json:"token_hash"` // SHA-256 of the raw token
	AccountID string    `json:"account_id"` // the account this provider is linked to
	Label     string    `json:"label"`      // human-readable label (e.g. hostname)
	Active    bool      `json:"active"`
	CreatedAt time.Time `json:"created_at"`
}

// DeviceAuthStore covers the RFC 8628-style device authorization flow and the
// long-lived provider tokens it mints for device-linked provider machines.
type DeviceAuthStore interface {
	// --- Device Authorization (RFC 8628-style) ---

	// CreateDeviceCode stores a new device authorization request.
	CreateDeviceCode(dc *DeviceCode) error

	// GetDeviceCode returns a device code by its device_code value.
	GetDeviceCode(deviceCode string) (*DeviceCode, error)

	// GetDeviceCodeByUserCode returns a device code by its user-facing code.
	GetDeviceCodeByUserCode(userCode string) (*DeviceCode, error)

	// ApproveDeviceCode links a device code to an account, marking it approved.
	ApproveDeviceCode(deviceCode, accountID string) error

	// DeleteExpiredDeviceCodes removes device codes that have passed their expiry.
	DeleteExpiredDeviceCodes() error

	// --- Provider Tokens (device-linked auth) ---

	// CreateProviderToken stores a long-lived provider auth token linked to an account.
	CreateProviderToken(token *ProviderToken) error

	// GetProviderToken validates a provider token and returns it.
	GetProviderToken(token string) (*ProviderToken, error)

	// RevokeProviderToken deactivates a provider token.
	RevokeProviderToken(token string) error
}
