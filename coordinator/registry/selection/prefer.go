package selection

// Prefer narrows a request-local pool in place, preserving its order. If no
// candidate matches, the original pool survives. Callers must not retain another
// view of the pool's backing slice.
func Prefer[T any](pool []T, prefer func(T) bool) []T {
	n := 0
	for _, candidate := range pool {
		if prefer(candidate) {
			pool[n] = candidate
			n++
		}
	}
	if n == 0 {
		return pool
	}
	clear(pool[n:])
	return pool[:n]
}
