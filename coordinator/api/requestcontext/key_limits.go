package requestcontext

import "context"

// keyIDFromContext returns the public key ID used for request usage attribution.
func KeyID(ctx context.Context) string {
	if k := APIKey(ctx); k != nil {
		return k.ID
	}
	return ""
}

// keyLimitMicroFromContext carries the spend cap into a pending request so
// provider-specific reservation top-ups enforce the same key limit.
func KeyLimitMicroUSD(ctx context.Context) *int64 {
	if k := APIKey(ctx); k != nil {
		return k.LimitMicroUSD
	}
	return nil
}

func KeyLimitReset(ctx context.Context) string {
	if k := APIKey(ctx); k != nil {
		return k.LimitReset
	}
	return ""
}
