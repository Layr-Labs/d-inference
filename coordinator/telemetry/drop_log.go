package telemetry

// CrossesPowerOfTen reports whether some power of ten p (1, 10, 100, …)
// satisfies before < p <= after. It is the throttle key for drop logging and
// works for multi-op drops, where a single increment could skip a threshold.
// The p > 0 guard stops the walk when p*10 overflows int64 past 10^18, so an
// after near math.MaxInt64 terminates instead of spinning.
func CrossesPowerOfTen(before, after int64) bool {
	for p := int64(1); p > 0 && p <= after; p *= 10 {
		if p > before {
			return true
		}
	}
	return false
}
