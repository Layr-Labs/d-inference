package selection

// BypassBreaker retries only when the breaker is the sole reason no route was
// selected. Busy or slow healthy providers must retain their retry signal.
func BypassBreaker(hasWinner bool, breakerRejected, capacityRejections, ttftRejections int) bool {
	return !hasWinner && breakerRejected > 0 && capacityRejections == 0 && ttftRejections == 0
}
