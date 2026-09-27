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

// selectRoutingCandidate ranks a request-local pool by adjusted service cost.
// Every candidate within nearTieCostWindowMs of the minimum is a near-tie,
// with or without cache adjustments in the pool. Inside that band a proven
// holder with a positive cache credit is preferred (the cheapest such holder);
// otherwise the existing least-busy spreading and the soft prefix affinity
// apply. A candidate carrying a restore penalty competes on strict cost only:
// it is retained only at the exact minimum, where it is an ordinary member of
// the band with no preference of its own. The pool itself remains immutable.
func selectRoutingCandidate(pool []*routingCandidate) (winner, runnerUp *routingCandidate, nearTieSize int, path SelectionPath) {
	return selectRoutingCandidateWithAffinity(pool, "")
}

func selectRoutingCandidateWithAffinity(pool []*routingCandidate, affinity string) (winner, runnerUp *routingCandidate, nearTieSize int, path SelectionPath) {
	if len(pool) == 0 {
		return nil, nil, 0, SelectionNone
	}

	// Retain the two lowest costs in input order. Once the winner is known, the
	// runner-up is the minimum unless it won, in which case it is the second.
	best := pool[0]
	var second *routingCandidate
	for _, candidate := range pool[1:] {
		if candidate.costMs < best.costMs {
			second, best = best, candidate
		} else if second == nil || candidate.costMs < second.costMs {
			second = candidate
		}
	}
	// A restore penalty is measured overhead the provider will pay. Such a
	// candidate never enters the spreading band: it is retained only at the
	// exact minimum, so it cannot displace a cheaper peer.
	isNear := func(c *routingCandidate) bool {
		if c.cacheEstimatedTTFTSavedMs < 0 {
			return c.costMs == best.costMs
		}
		return math.Abs(c.costMs-best.costMs) <= nearTieCostWindowMs
	}

	// One pass over the band finds the preferred credited holder and the least
	// busy candidate. Count queue ties independently of pending ties so the
	// reported selection path remains precise.
	var credited *routingCandidate
	queueTies := 0
	for _, candidate := range pool {
		if !isNear(candidate) {
			continue
		}
		nearTieSize++
		if candidate.breakdown.CacheDiscountMs > 0 &&
			(credited == nil || cacheCreditRanksAbove(candidate, credited)) {
			credited = candidate
		}
		if winner == nil || candidate.effectiveQueue < winner.effectiveQueue {
			winner, queueTies = candidate, 1
		} else if candidate.effectiveQueue == winner.effectiveQueue {
			queueTies++
			if candidate.snapshot.totalPending < winner.snapshot.totalPending {
				winner = candidate
			}
		}
	}
	if credited != nil && nearTieSize > 1 {
		// The band contains a proven holder and at least one other candidate:
		// the credit, not load spreading, decides. A lone candidate in the
		// band is a unique minimum whether or not it is credited. Holders
		// that tie on every ranking term are spread uniformly, as cold
		// near-ties are: a stable identity order would send every request of
		// a same-prefix burst to one holder, whose commit then forces the
		// rest to rescan.
		winner, path = credited, SelectionCacheCredit
		ties := 0
		for _, candidate := range pool {
			if candidate.breakdown.CacheDiscountMs > 0 && isNear(candidate) && cacheCreditEquivalent(candidate, credited) {
				ties++
			}
		}
		if ties > 1 {
			chosen := rand.Intn(ties)
			for _, candidate := range pool {
				if candidate.breakdown.CacheDiscountMs <= 0 || !isNear(candidate) || !cacheCreditEquivalent(candidate, credited) {
					continue
				}
				if chosen == 0 {
					winner = candidate
					break
				}
				chosen--
			}
		}
		runnerUp = best
		if winner == best {
			runnerUp = second
		}
		return winner, runnerUp, nearTieSize, path
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
		if affinity != "" {
			if preferred := cacheAffinityWinner(pool, isEquivalent, affinity); preferred != nil {
				winner, path = preferred, SelectionPrefixAffinity
			}
		}
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

// cacheCreditRanksAbove orders credited near-ties: the lowest adjusted service
// cost (the credit is already inside it, so a larger credit and a lighter load
// both rank higher), then the larger credit, the fresher evidence, and the
// lighter queue and pending load. Candidates equal on every term are
// equivalent (cacheCreditEquivalent) and are spread at random; a rescan over
// the same pool therefore selects from the same equivalent set.
func cacheCreditRanksAbove(a, b *routingCandidate) bool {
	if a.costMs != b.costMs {
		return a.costMs < b.costMs
	}
	if a.breakdown.CacheDiscountMs != b.breakdown.CacheDiscountMs {
		return a.breakdown.CacheDiscountMs > b.breakdown.CacheDiscountMs
	}
	if a.cacheEvidenceWeight != b.cacheEvidenceWeight {
		return a.cacheEvidenceWeight > b.cacheEvidenceWeight
	}
	if a.effectiveQueue != b.effectiveQueue {
		return a.effectiveQueue < b.effectiveQueue
	}
	return a.snapshot.totalPending < b.snapshot.totalPending
}

func cacheCreditEquivalent(a, b *routingCandidate) bool {
	return a.costMs == b.costMs && a.breakdown.CacheDiscountMs == b.breakdown.CacheDiscountMs &&
		a.cacheEvidenceWeight == b.cacheEvidenceWeight && a.effectiveQueue == b.effectiveQueue &&
		a.snapshot.totalPending == b.snapshot.totalPending
}
