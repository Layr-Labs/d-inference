package access

import (
	"context"

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

// RequestIDFromContext returns the per-request correlation ID set by
// the logging middleware. Empty if the request didn't pass through the
// middleware (e.g. raw test handlers).
func RequestIDFromContext(ctx context.Context) string {
	if v, ok := ctx.Value(ctxKeyRequestID).(string); ok {
		return v
	}
	return ""
}

// ConsumerKeyFromContext retrieves the authenticated consumer's API key
// from the request context. The key is stored by RequireAuth middleware
// and used as the consumer's identity for billing and usage tracking.
func ConsumerKeyFromContext(ctx context.Context) string {
	if v, ok := ctx.Value(ctxKeyConsumer).(string); ok {
		return v
	}
	return ""
}

// APIKeyFromContext returns the authenticated API key record set by RequireAuth,
// carrying the per-key limits used by the request path. Returns nil for
// non-API-key auth (Privy JWT, admin key) and for account-scoped/legacy keys
// without per-key metadata.
func APIKeyFromContext(ctx context.Context) *store.APIKey {
	if v, ok := ctx.Value(ctxKeyAPIKey).(*store.APIKey); ok {
		return v
	}
	return nil
}

// KeyIDFromContext returns the public ID of the authenticated API key, or ""
// for account-scoped/legacy callers. Used to stamp per-key usage attribution
// onto in-flight requests.
func KeyIDFromContext(ctx context.Context) string {
	if k := APIKeyFromContext(ctx); k != nil {
		return k.ID
	}
	return ""
}

// KeyLimitMicroFromContext / KeyLimitResetFromContext expose the calling key's
// spend cap so it can be stamped onto a PendingRequest and re-enforced when a
// provider's custom price tops up the reservation. nil = no per-key cap.
func KeyLimitMicroFromContext(ctx context.Context) *int64 {
	if k := APIKeyFromContext(ctx); k != nil {
		return k.LimitMicroUSD
	}
	return nil
}

func KeyLimitResetFromContext(ctx context.Context) string {
	if k := APIKeyFromContext(ctx); k != nil {
		return k.LimitReset
	}
	return ""
}

// WithConsumer records the authenticated account identity, never a bearer secret.
func WithConsumer(ctx context.Context, accountID string) context.Context {
	return context.WithValue(ctx, ctxKeyConsumer, accountID)
}

// WithAPIKey carries the authenticated key metadata for request admission.
func WithAPIKey(ctx context.Context, key *store.APIKey) context.Context {
	return context.WithValue(ctx, ctxKeyAPIKey, key)
}

// WithRequestID records the transport's request correlation ID.
func WithRequestID(ctx context.Context, id string) context.Context {
	return context.WithValue(ctx, ctxKeyRequestID, id)
}
