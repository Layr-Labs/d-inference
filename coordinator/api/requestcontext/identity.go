// Package requestcontext carries authenticated identity and request correlation
// across the coordinator's HTTP middleware and endpoint packages.
package requestcontext

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/store"
)

type key int

const (
	accountKey key = iota
	requestIDKey
	apiKeyKey
)

// WithAccountID attaches the authenticated account identity to ctx.
func WithAccountID(ctx context.Context, accountID string) context.Context {
	return context.WithValue(ctx, accountKey, accountID)
}

// AccountID returns the authenticated account, or an empty string before auth.
func AccountID(ctx context.Context) string {
	value, _ := ctx.Value(accountKey).(string)
	return value
}

// WithRequestID attaches the request correlation ID to ctx.
func WithRequestID(ctx context.Context, requestID string) context.Context {
	return context.WithValue(ctx, requestIDKey, requestID)
}

// RequestID returns the request correlation ID, or an empty string if absent.
func RequestID(ctx context.Context) string {
	value, _ := ctx.Value(requestIDKey).(string)
	return value
}

// WithAPIKey attaches the authenticated key record, including its spend limits.
func WithAPIKey(ctx context.Context, record *store.APIKey) context.Context {
	return context.WithValue(ctx, apiKeyKey, record)
}

// APIKey returns the authenticated key record. Non-key authentication has no
// record unless its middleware explicitly attaches one.
func APIKey(ctx context.Context) *store.APIKey {
	value, _ := ctx.Value(apiKeyKey).(*store.APIKey)
	return value
}
