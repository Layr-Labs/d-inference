package identity

// Usage contains cardinalities only, never provider identities, tokens or nonces.
// The coverage sweep reports these gauges to expose retained-state growth.
type Usage struct {
	ReservationLocks int
	LoopGenerations  int
	LoopTokens       int
	LoopGeneration   uint64
	LocalBudgets     int
	DurableBudgets   int
}

func (t *Throttle) Usage() Usage {
	t.mu.Lock()
	defer t.mu.Unlock()
	return Usage{
		ReservationLocks: len(t.reservationLocks),
		LoopGenerations:  len(t.loopGenerations),
		LoopTokens:       len(t.loopTokens),
		LoopGeneration:   t.loopGeneration.Load(),
		LocalBudgets:     len(t.lastPush),
		DurableBudgets:   len(t.durableNextPush),
	}
}
