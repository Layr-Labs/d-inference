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
	return selection.Project(id, &c.firstContent, &c.breakdown, c.cacheEstimatedTTFTSavedMs, c.cacheEvidenceWeight, c.cacheAffinityEligible)
}

// selectFirstContentCandidate projects immutable candidate values into policy
// inputs. Ownership, feasibility and decode quality are narrowed by the caller;
// provider pointers and random state never cross the policy boundary.
func selectFirstContentCandidate(pool []*routingCandidate, affinity string) (winner, runnerUp *routingCandidate, nearTieSize int, path SelectionPath) {
	if len(pool) == 0 {
		return nil, nil, 0, SelectionNone
	}
	decision := selection.Select(pool, selectionCandidate, rand.Intn, affinity)
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
