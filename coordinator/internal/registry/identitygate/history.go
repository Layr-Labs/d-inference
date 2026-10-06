package identitygate

import (
	"sort"
	"time"
)

// CapacityRateWindow is the strict sliding horizon of capacity outcomes.
const CapacityRateWindow = 5 * time.Minute

// PruneWindowedOutcomes advances the expired prefix without compacting the
// remaining history. Outcomes exactly at the cutoff are excluded.
func PruneWindowedOutcomes(outcomes []time.Time, now time.Time) []time.Time {
	cutoff := now.Add(-CapacityRateWindow)
	first := sort.Search(len(outcomes), func(i int) bool {
		return outcomes[i].After(cutoff)
	})
	if first == 0 {
		return outcomes
	}
	if first == len(outcomes) {
		return outcomes[:0]
	}
	return outcomes[first:]
}

// CountInWindow reads the same strict horizon without mutating the history.
func CountInWindow(outcomes []time.Time, now time.Time) int {
	cutoff := now.Add(-CapacityRateWindow)
	first := sort.Search(len(outcomes), func(i int) bool {
		return outcomes[i].After(cutoff)
	})
	return len(outcomes) - first
}

// MergeChronologicalTimestamps combines ordered identity histories. Equal
// timestamps remain separate outcomes; a move to an empty identity reuses src.
func MergeChronologicalTimestamps(dst, src []time.Time) []time.Time {
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
