package store

import "time"

// CloneTimePtr detaches an optional timestamp from a stored record.
func CloneTimePtr(t *time.Time) *time.Time {
	if t == nil {
		return nil
	}
	cp := *t
	return &cp
}

// CloneInt64Ptr detaches an optional integer from a stored record.
func CloneInt64Ptr(v *int64) *int64 {
	if v == nil {
		return nil
	}
	cp := *v
	return &cp
}
