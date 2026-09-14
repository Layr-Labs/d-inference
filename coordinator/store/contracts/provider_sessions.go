package contracts

import (
	"context"
	"time"
)

// ProviderSession is one connect→disconnect lifecycle of a provider machine.
// connected_at/disconnected_at bound the session; last_seen is the most recent
// heartbeat within it. disconnected_at == nil means the session is still open.
// These rows are the durable source for uptime/downtime history (the providers
// table only keeps a single mutable last_seen).
type ProviderSession struct {
	ID               int64      `json:"id"`
	SessionID        string     `json:"session_id"` // providers.id for this connection
	SerialNumber     string     `json:"serial_number"`
	AccountID        string     `json:"account_id"`
	ProviderKey      string     `json:"provider_key"` // X25519 public key — unifies sessions↔earnings identity (design §8)
	ConnectedAt      time.Time  `json:"connected_at"`
	LastSeen         time.Time  `json:"last_seen"`
	DisconnectedAt   *time.Time `json:"disconnected_at,omitempty"`
	DisconnectReason string     `json:"disconnect_reason"`
}

// ProviderSessionStore owns durable connection lifetime records.
type ProviderSessionStore interface {
	// OpenProviderSession records the start of a provider connection (one row per
	// websocket session). serial/account may be empty at connect time and are
	// backfilled by TouchProviderSession once attestation/linking completes.
	OpenProviderSession(ctx context.Context, sessionID, serial, accountID string) error

	// TouchProviderSession updates the open session's last_seen heartbeat and
	// backfills serial/account/provider_key if they were unknown at open time.
	TouchProviderSession(ctx context.Context, sessionID, serial, accountID, providerKey string, lastSeen time.Time) error

	// CloseProviderSession marks the open session for sessionID as ended.
	CloseProviderSession(ctx context.Context, sessionID, reason string, when time.Time) error

	// CloseOpenProviderSessions closes sessions still marked open whose last
	// heartbeat (last_seen) predates staleBefore — i.e. genuinely orphaned by a
	// dead prior coordinator process. The staleBefore fence is what makes this
	// safe under a blue-green/rolling deploy over a shared DB: a session still
	// live on the OLD instance keeps getting TouchProviderSession heartbeats, so
	// its last_seen stays fresh and is NOT closed by the NEW instance's startup
	// reconcile. Returns the number of sessions closed.
	CloseOpenProviderSessions(ctx context.Context, staleBefore time.Time) (int, error)
}
