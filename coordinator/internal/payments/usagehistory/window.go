// Package usagehistory maintains the bounded, insertion-ordered usage window.
package usagehistory

const limit = 100

// Append keeps the newest 100 entries, growing lazily and reusing the full
// backing array. The caller owns synchronization and the returned slice.
func Append[T any](entries []T, entry T) []T {
	if len(entries) < limit {
		if len(entries) == cap(entries) {
			next := min(max(2*cap(entries), 1), limit)
			grown := make([]T, len(entries), next)
			copy(grown, entries)
			entries = grown
		}
		return append(entries, entry)
	}
	copy(entries, entries[1:])
	entries[len(entries)-1] = entry
	return entries
}
