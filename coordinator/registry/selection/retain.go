package selection

// Retain repeatedly selects from the remaining pool, excluding the primary.
// It preserves the selector's tie and affinity semantics instead of introducing
// a second ordering comparator for provisional alternates.
func Retain[T comparable, U any](pool []T, winner T, limit int, choose func([]T) T, retain func(T) U) []U {
	remaining := make([]T, 0, len(pool))
	for _, candidate := range pool {
		if candidate != winner {
			remaining = append(remaining, candidate)
		}
	}
	entries := make([]U, 0, min(len(remaining), limit))
	for len(remaining) > 0 && len(entries) < limit {
		chosen := choose(remaining)
		entries = append(entries, retain(chosen))
		for i, candidate := range remaining {
			if candidate == chosen {
				remaining = append(remaining[:i], remaining[i+1:]...)
				break
			}
		}
	}
	return entries
}
