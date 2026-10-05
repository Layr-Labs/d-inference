package store

import "errors"

// ErrInsufficientBalance is returned by Debit when the account has
// insufficient funds (or does not exist). Callers should check with
// errors.Is to distinguish this from transient DB errors.
var ErrInsufficientBalance = errors.New("insufficient balance or account not found")

// ErrNotFound is wrapped by lookup methods when no row matches. Callers that
// take a different action on a true miss vs a transient store failure (e.g.
// the Stripe webhook state machine) must check with errors.Is rather than
// treating every error as not-found.
var ErrNotFound = errors.New("not found")

// Store is the union of every storage-domain sub-interface (defined in
// interface_domains.go). It was split from a single ~150-method god-interface
// into composed domains so callers can depend on a narrow slice of the
// persistence surface; the full method set — and both the MemoryStore and
// PostgresStore implementations — are unchanged.
//
// Telemetry events are forwarded to Datadog (Logs API + DogStatsD) for durable
// storage and querying, not persisted via this Store.
type Store interface {
	APIKeyStore
	UsageStore
	TelemetryStore
	RequestOutcomeStore
	LedgerStore
	BillingStore
	ModelRegistryStore
	ReleaseStore
	UserStore
	DeviceAuthStore
	InviteStore
	ProviderEarningsStore
	ProviderStore
}
