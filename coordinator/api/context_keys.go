package api

import (
	"context"
	"crypto/rand"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// contextKey is an unexported type for context keys in this package.
// Using a distinct type prevents collisions with context keys from other packages.
type contextKey int

const (
	ctxKeyConsumer contextKey = iota
	ctxKeyRequestID
	ctxKeyAPIKey
)

// requestIDFromContext returns the per-request correlation ID set by
// the logging middleware. Empty if the request didn't pass through the
// middleware (e.g. raw test handlers).
func requestIDFromContext(ctx context.Context) string {
	if v, ok := ctx.Value(ctxKeyRequestID).(string); ok {
		return v
	}
	return ""
}

// cryptoRand is a small wrapper to read random bytes. Defined as a var
// so tests can stub it if needed; production uses crypto/rand.Read.
var cryptoRand = rand.Read

// consumerKeyFromContext retrieves the authenticated consumer's API key
// from the request context. The key is stored by requireAuth middleware
// and used as the consumer's identity for billing and usage tracking.
func consumerKeyFromContext(ctx context.Context) string {
	if v, ok := ctx.Value(ctxKeyConsumer).(string); ok {
		return v
	}
	return ""
}

// apiKeyFromContext returns the authenticated API key record set by requireAuth,
// carrying the per-key limits used by the request path. Returns nil for
// non-API-key auth (Privy JWT, admin key) and for account-scoped/legacy keys
// without per-key metadata.
func apiKeyFromContext(ctx context.Context) *store.APIKey {
	if v, ok := ctx.Value(ctxKeyAPIKey).(*store.APIKey); ok {
		return v
	}
	return nil
}

// keyIDFromContext returns the public ID of the authenticated API key, or ""
// for account-scoped/legacy callers. Used to stamp per-key usage attribution
// onto in-flight requests.
func keyIDFromContext(ctx context.Context) string {
	if k := apiKeyFromContext(ctx); k != nil {
		return k.ID
	}
	return ""
}

// keyLimitMicroFromContext / keyLimitResetFromContext expose the calling key's
// spend cap so it can be stamped onto a PendingRequest and re-enforced when a
// provider's custom price tops up the reservation. nil = no per-key cap.
func keyLimitMicroFromContext(ctx context.Context) *int64 {
	if k := apiKeyFromContext(ctx); k != nil {
		return k.LimitMicroUSD
	}
	return nil
}

func keyLimitResetFromContext(ctx context.Context) string {
	if k := apiKeyFromContext(ctx); k != nil {
		return k.LimitReset
	}
	return ""
}
