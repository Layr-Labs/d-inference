package store

import (
	"time"
)

func cloneTimePtr(t *time.Time) *time.Time {
	if t == nil {
		return nil
	}
	cp := *t
	return &cp
}

func cloneInt64Ptr(v *int64) *int64 {
	if v == nil {
		return nil
	}
	cp := *v
	return &cp
}

// cloneAPIKey returns a deep copy of a key record so callers can never mutate
// the store's internal state through the returned pointer.
func cloneAPIKey(rec *APIKey) *APIKey {
	if rec == nil {
		return nil
	}
	cp := *rec
	cp.LimitMicroUSD = cloneInt64Ptr(rec.LimitMicroUSD)
	cp.RPMLimit = cloneInt64Ptr(rec.RPMLimit)
	cp.ITPMLimit = cloneInt64Ptr(rec.ITPMLimit)
	cp.OTPMLimit = cloneInt64Ptr(rec.OTPMLimit)
	cp.ExpiresAt = cloneTimePtr(rec.ExpiresAt)
	cp.LastUsedAt = cloneTimePtr(rec.LastUsedAt)
	cp.AllowedModels = append([]string(nil), rec.AllowedModels...)
	return &cp
}
