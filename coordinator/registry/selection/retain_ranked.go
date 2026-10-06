package selection

// RetainRanked projects immutable inputs once while repeatedly applying the same
// ranking policy. Each removal preserves both input order and draw order; rank
// classes are recomputed for every alternate rather than sorted once.
func RetainRanked[T comparable, U any](pool []T, winner T, limit int, project func(T) Candidate, draw func(int) int, affinity string, retain func(T) U) []U {
	remaining := make([]T, 0, len(pool))
	var inline [512]Candidate
	values := inline[:0]
	if len(pool) > len(inline) {
		values = make([]Candidate, 0, len(pool))
	}
	for _, candidate := range pool {
		if candidate != winner {
			remaining = append(remaining, candidate)
			values = append(values, project(candidate))
		}
	}
	entries := make([]U, 0, min(len(remaining), limit))
	for len(remaining) > 0 && len(entries) < limit {
		ranking := Rank(values)
		decision := ranking.Choose(values, draw(ranking.Choices), affinity)
		i := decision.Winner
		entries = append(entries, retain(remaining[i]))
		remaining = append(remaining[:i], remaining[i+1:]...)
		values = append(values[:i], values[i+1:]...)
	}
	return entries
}
