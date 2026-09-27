package api

import "github.com/eigeninference/d-inference/coordinator/registry"

func (s *Server) emitCacheOpportunity(pr *registry.PendingRequest) {
	if pr == nil || !pr.CacheOpportunity.Evaluated {
		return
	}
	labels := []MetricLabel{{"model", s.cacheModelLabel(pr.Model)}, {"reason", pr.CacheOpportunityReason()}}
	s.cacheModelCount("opportunity", 1, labels...)
	if pr.CacheOpportunity.AffinityApplied {
		s.cacheModelCount("opportunity_affinity", 1, labels...)
	}
	// Aggregate numeric values only: never put a boundary, scope or affinity
	// key in a metric, log or response. Ratios use this same population.
	s.cacheModelCount("opportunity_repeated_prefix_tokens", int64(pr.CacheOpportunity.RepeatedPrefixTokens), labels...)
	s.cacheModelCount("opportunity_matching_holders", int64(pr.CacheOpportunity.MatchingHolders), labels...)
	s.cacheModelCount("opportunity_valid_holders", int64(pr.CacheOpportunity.ValidHolders), labels...)
	s.cacheModelCount("opportunity_credited_candidates", int64(pr.CacheOpportunity.CreditedCandidates), labels...)
	s.cacheModelCount("opportunity_usable_candidates", int64(pr.CacheOpportunity.UsableCandidates), labels...)
}
