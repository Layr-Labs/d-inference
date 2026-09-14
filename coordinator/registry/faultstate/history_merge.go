package faultstate

import (
	"time"
)

// mergeChronologicalTimestamps returns the oldest-to-newest union of two
// already-ordered histories. Identity migration is rare, so allocate only when
// both identities already hold state; the common move-to-empty case reuses the
// source slice. Equal timestamps remain distinct outcomes.
func mergeChronologicalTimestamps(dst, src []time.Time) []time.Time {
	if len(dst) == 0 {
		return src
	}
	if len(src) == 0 {
		return dst
	}

	merged := make([]time.Time, 0, len(dst)+len(src))
	i, j := 0, 0
	for i < len(dst) && j < len(src) {
		if !dst[i].After(src[j]) {
			merged = append(merged, dst[i])
			i++
		} else {
			merged = append(merged, src[j])
			j++
		}
	}
	merged = append(merged, dst[i:]...)
	merged = append(merged, src[j:]...)
	return merged
}
