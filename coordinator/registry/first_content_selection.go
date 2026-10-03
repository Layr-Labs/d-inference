package registry

import (
	"math/rand"

	"github.com/eigeninference/d-inference/coordinator/registry/selection"
)

func selectionCandidate(c *routingCandidate) selection.Candidate {
	id := ""
	if c.provider != nil {
		id = c.provider.ID
	}
	return selection.Candidate{
		ProviderID: id,
		ExpectedMs: c.firstContent.ExpectedMs, HealthMs: c.breakdown.HealthMs,
		CapacityRateMs: c.breakdown.CapacityRateMs, ServiceMs: c.firstContent.ServiceMs,
		CachedTokens: c.firstContent.CachedTokens, CacheSavedMs: c.cacheEstimatedTTFTSavedMs,
		CacheEvidenceWeight: c.cacheEvidenceWeight, AffinityEligible: c.cacheAffinityEligible,
	}
}

// selectFirstContentCandidate projects immutable candidate values into policy
// inputs. Ownership, feasibility and decode quality are narrowed by the caller;
// provider pointers and random state never cross the policy boundary.
func selectFirstContentCandidate(pool []*routingCandidate, affinity string) (winner, runnerUp *routingCandidate, nearTieSize int, path SelectionPath) {
	if len(pool) == 0 {
		return nil, nil, 0, SelectionNone
	}
	// Keep ordinary fleet scans allocation-free while passing only detached
	// values across the policy boundary. Larger fleets spill once, not per node.
	var inline [512]selection.Candidate
	values := inline[:0]
	if len(pool) > len(inline) {
		values = make([]selection.Candidate, 0, len(pool))
	}
	for _, c := range pool {
		values = append(values, selectionCandidate(c))
	}
	ranking := selection.Rank(values)
	decision := ranking.Choose(values, rand.Intn(ranking.Choices), affinity)
	if decision.Winner >= 0 {
		winner = pool[decision.Winner]
	}
	if decision.RunnerUp >= 0 {
		runnerUp = pool[decision.RunnerUp]
	}
	switch decision.Path {
	case selection.UniqueMin:
		path = SelectionUniqueMin
	case selection.TiePending:
		path = SelectionTiePending
	case selection.Random:
		path = SelectionRandom
	case selection.PrefixAffinity:
		path = SelectionPrefixAffinity
	case selection.CacheCredit:
		path = SelectionCacheCredit
	}
	return winner, runnerUp, decision.NearTieSize, path
}
