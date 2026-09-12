package registry

import (
	"math"
	"math/rand"
)

// preferRoutingCandidates narrows a request-local pool in place, preserving its
// order. Preferences are soft: if nothing matches, the original pool survives.
// Callers must not retain another view of the pool's backing slice.
func preferRoutingCandidates(pool []*routingCandidate, prefer func(*routingCandidate) bool) []*routingCandidate {
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

// selectRoutingCandidate uses adjusted service cost when a live cache estimate
// can affect this pool. Queue and pending work already contribute to that cost;
// they break only exact cost ties. Pools with no cache adjustment retain the
// existing near-cost load spreading. The pool itself remains immutable.
func selectRoutingCandidate(pool []*routingCandidate) (winner, runnerUp *routingCandidate, nearTieSize int, path SelectionPath) {
	if len(pool) == 0 {
		return nil, nil, 0, SelectionNone
	}

	// Retain the two lowest costs in input order. Once the winner is known, the
	// runner-up is the minimum unless it won, in which case it is the second.
	best := pool[0]
	hasCacheAdjustment := best.breakdown.CacheDiscountMs > 0 || best.cacheEstimatedTTFTSavedMs < 0
	var second *routingCandidate
	for _, candidate := range pool[1:] {
		hasCacheAdjustment = hasCacheAdjustment || candidate.breakdown.CacheDiscountMs > 0 || candidate.cacheEstimatedTTFTSavedMs < 0
		if candidate.costMs < best.costMs {
			second, best = best, candidate
		} else if second == nil || candidate.costMs < second.costMs {
			second = candidate
		}
	}
	window := nearTieCostWindowMs
	if hasCacheAdjustment {
		window = 0
	}
	isNear := func(c *routingCandidate) bool {
		return math.Abs(c.costMs-best.costMs) <= window
	}

	// Find the least busy near-cost candidate. Count queue ties independently
	// of pending ties so the reported selection path remains precise.
	queueTies := 0
	for _, candidate := range pool {
		if !isNear(candidate) {
			continue
		}
		nearTieSize++
		if winner == nil || candidate.effectiveQueue < winner.effectiveQueue {
			winner, queueTies = candidate, 1
		} else if candidate.effectiveQueue == winner.effectiveQueue {
			queueTies++
			if candidate.snapshot.totalPending < winner.snapshot.totalPending {
				winner = candidate
			}
		}
	}
	queue, pending := winner.effectiveQueue, winner.snapshot.totalPending
	isEquivalent := func(c *routingCandidate) bool {
		return c.effectiveQueue == queue && c.snapshot.totalPending == pending && isNear(c)
	}

	choices := 0
	for _, candidate := range pool {
		if isEquivalent(candidate) {
			choices++
		}
	}
	switch {
	case choices > 1:
		// One uniform draw, followed by an order-preserving lookup, matches the
		// former slice-based choice without allocating the slice.
		chosen := rand.Intn(choices)
		for _, candidate := range pool {
			if !isEquivalent(candidate) {
				continue
			}
			if chosen == 0 {
				winner = candidate
				break
			}
			chosen--
		}
		path = SelectionRandom
	case nearTieSize == 1:
		path = SelectionUniqueMin
	case queueTies > 1:
		path = SelectionTiePending
	default:
		path = SelectionTieQueue
	}

	runnerUp = best
	if winner == best {
		runnerUp = second
	}
	return winner, runnerUp, nearTieSize, path
}
