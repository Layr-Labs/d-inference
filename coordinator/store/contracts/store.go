package contracts

import (
	"errors"
)

// ErrInsufficientBalance is returned by Debit when the account has
// insufficient funds (or does not exist). Callers should check with
// errors.Is to distinguish this from transient DB errors.
var ErrInsufficientBalance = errors.New("insufficient balance or account not found")

// ErrNotFound is wrapped by lookup methods when no row matches. Callers that
// take a different action on a true miss vs a transient store failure (e.g.
// the Stripe webhook state machine) must check with errors.Is rather than
// treating every error as not-found.
var ErrNotFound = errors.New("not found")

// Store composes the persistence domains. Consumers can depend on a narrower
// domain contract; backend-only capabilities remain optional through As.
//
// Telemetry events (TelemetryEventRecord) are forwarded to Datadog (Logs API +
// DogStatsD) for durable storage and querying, not persisted via this Store.
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
