package registry

import "github.com/eigeninference/d-inference/coordinator/registry/selection"

// preferRoutingCandidates narrows a request-local pool in place, preserving its
// order. Preferences are soft: if nothing matches, the original pool survives.
// Callers must not retain another view of the pool's backing slice.
func preferRoutingCandidates(pool []*routingCandidate, prefer func(*routingCandidate) bool) []*routingCandidate {
	return selection.Prefer(pool, prefer)
}

func selectRoutingCandidateWithAffinity(pool []*routingCandidate, affinity string) (winner, runnerUp *routingCandidate, nearTieSize int, path SelectionPath) {
	return selectFirstContentCandidate(pool, affinity)
}
