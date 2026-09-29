package registry

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

// selectRoutingCandidate applies the active first-content policy. All callers
// narrow ownership, feasibility and decode quality before invoking it.
func selectRoutingCandidate(pool []*routingCandidate) (winner, runnerUp *routingCandidate, nearTieSize int, path SelectionPath) {
	return selectFirstContentCandidate(pool, "")
}

func selectRoutingCandidateWithAffinity(pool []*routingCandidate, affinity string) (winner, runnerUp *routingCandidate, nearTieSize int, path SelectionPath) {
	return selectFirstContentCandidate(pool, affinity)
}
