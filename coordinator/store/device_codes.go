package store

import "time"

// DeviceCodeStore covers the RFC 8628-style device authorization flow used to
// link provider machines to user accounts.
type DeviceCodeStore interface {
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
}

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
