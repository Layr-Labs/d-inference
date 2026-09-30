package registry

import "math/rand"

// firstContentRankMs retains health/capacity derating when narrowing the fast
// band. Those policy penalties are deliberately separate from elapsed-time
// forecasts: unhealthy hardware does not become healthy merely by advertising
// a faster prefill EWMA.
func firstContentRankMs(c *routingCandidate) float64 {
	return c.firstContent.ExpectedMs + c.breakdown.HealthMs + c.breakdown.CapacityRateMs
}

// selectFirstContentCandidate applies one policy to scans, plans and quotes.
// Owner scope, feasibility and decode quality are narrowed before this call.
// Within 100 ms of the fastest expected delivery, choose the least committed
// whole-Mac expected service. Cache proof/affinity only breaks close work ties.
func selectFirstContentCandidate(pool []*routingCandidate, affinity string) (winner, runnerUp *routingCandidate, nearTieSize int, path SelectionPath) {
	if len(pool) == 0 {
		return nil, nil, 0, SelectionNone
	}
	best := pool[0]
	for _, c := range pool[1:] {
		if firstContentRankMs(c) < firstContentRankMs(best) {
			best = c
		}
	}
	isNear := func(c *routingCandidate) bool {
		return firstContentRankMs(c) <= firstContentRankMs(best)+firstContentFastBandMs
	}
	for _, c := range pool {
		if !isNear(c) {
			continue
		}
		nearTieSize++
		if winner == nil || c.firstContent.ServiceMs < winner.firstContent.ServiceMs {
			winner = c
		}
	}
	work := winner.firstContent.ServiceMs
	isWorkTie := func(c *routingCandidate) bool { return isNear(c) && c.firstContent.ServiceMs == work }
	// Prefer validated cache benefit only after service work has been compared.
	credited := false
	creditWeight := 0.0
	for _, c := range pool {
		if isWorkTie(c) && c.firstContent.CachedTokens > 0 && c.cacheEstimatedTTFTSavedMs > 0 {
			credited = true
			creditWeight = max(creditWeight, c.cacheEvidenceWeight)
		}
	}
	isEquivalent := func(c *routingCandidate) bool {
		return isWorkTie(c) && (!credited || (c.firstContent.CachedTokens > 0 && c.cacheEstimatedTTFTSavedMs > 0 && c.cacheEvidenceWeight == creditWeight))
	}
	choices := 0
	for _, c := range pool {
		if isEquivalent(c) {
			choices++
		}
	}
	chosen := rand.Intn(choices)
	for _, c := range pool {
		if !isEquivalent(c) {
			continue
		}
		if chosen == 0 {
			winner = c
			break
		}
		chosen--
	}
	switch {
	case nearTieSize == 1:
		path = SelectionUniqueMin
	case credited:
		path = SelectionCacheCredit
	case choices > 1:
		path = SelectionRandom
	default:
		path = SelectionTiePending
	}
	if affinity != "" && choices > 1 {
		if preferred := cacheAffinityWinner(pool, isEquivalent, affinity); preferred != nil {
			winner, path = preferred, SelectionPrefixAffinity
		}
	}
	for _, c := range pool {
		if c != winner && (runnerUp == nil || firstContentRankMs(c) < firstContentRankMs(runnerUp)) {
			runnerUp = c
		}
	}
	return winner, runnerUp, nearTieSize, path
}
