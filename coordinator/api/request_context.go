package api

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func requestIDFromContext(ctx context.Context) string     { return requestcontext.RequestID(ctx) }
func consumerKeyFromContext(ctx context.Context) string   { return requestcontext.AccountID(ctx) }
func apiKeyFromContext(ctx context.Context) *store.APIKey { return requestcontext.APIKey(ctx) }

// keyIDFromContext returns the public key ID used for request usage attribution.
func keyIDFromContext(ctx context.Context) string {
	if k := requestcontext.APIKey(ctx); k != nil {
		return k.ID
	}
	return ""
}

// keyLimitMicroFromContext carries the spend cap into a pending request so
// provider-specific reservation top-ups enforce the same key limit.
func keyLimitMicroFromContext(ctx context.Context) *int64 {
	if k := requestcontext.APIKey(ctx); k != nil {
		return k.LimitMicroUSD
	}
	return nil
}

func keyLimitResetFromContext(ctx context.Context) string {
	if k := requestcontext.APIKey(ctx); k != nil {
		return k.LimitReset
	}
	return ""
}
