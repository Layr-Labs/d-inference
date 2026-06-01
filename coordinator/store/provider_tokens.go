package store

import "time"

// ProviderTokenStore covers long-lived provider auth tokens minted when a
// device code is approved.
type ProviderTokenStore interface {
	// CreateProviderToken stores a long-lived provider auth token linked to an account.
	CreateProviderToken(token *ProviderToken) error

	// GetProviderToken validates a provider token and returns it.
	GetProviderToken(token string) (*ProviderToken, error)

	// RevokeProviderToken deactivates a provider token.
	RevokeProviderToken(token string) error
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
