package cachedirectory

import (
	"time"
)

type Match[C comparable] struct {
	Holder         Holder[C]
	Tier           string
	EvidenceWeight float64
	QueryTime      time.Time
}

// matchingHolders computes one keyed digest per request boundary, regardless
// of fleet size. Each tier bucket contains at most maxHolders machines, even
// when every machine has a different epoch. No provider lock or eligibility
// check runs while holding the directory lock.
func (t *Directory[C]) MatchingHolders(
	plan Plan, routeKey []byte, mode string, now time.Time,
) []Match[C] {
	if t == nil || mode != CacheRoutingOn || !plan.Present() || len(routeKey) == 0 ||
		plan.Generation != t.generation || t.generation.Revoked() {
		return nil
	}
	keys := make([]string, len(plan.Boundaries))
	for i, anchor := range plan.Boundaries {
		keys[i] = BoundaryKey(routeKey, plan, anchor)
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.generation.Revoked() {
		return nil
	}
	t.sweepIfDueLocked(now)
	out := make([]Match[C], 0)
	for i := len(plan.Boundaries) - 1; i >= 0; i-- {
		anchor := plan.Boundaries[i]
		for _, tier := range [...]string{"ssd", "memory"} {
			key := TierKey(keys[i], tier)
			for providerID := range t.holders[key] {
				holder, live := t.activeHolderLocked(key, providerID, now)
				if !live || holder.ModelAggregateHash != plan.ModelAggregateHash ||
					holder.PromptContractID != plan.PromptContractID || holder.Anchor != anchor ||
					anchor.TokenCount <= holder.RequiredRecomputeTokens {
					continue
				}
				out = append(out, Match[C]{Holder: holder, Tier: tier, EvidenceWeight: EvidenceWeight(holder, now), QueryTime: now})
			}
		}
	}
	return out
}

// cacheEvidenceWeight is a conservative age policy, not an empirically fitted
// hit probability. Capture it once per query so scan and reservation use the
// same evidence weight even as the wall clock advances between them.
func EvidenceWeight[C comparable](holder Holder[C], now time.Time) float64 {
	lifetime := holder.ExpiresAt.Sub(holder.UpdatedAt)
	if lifetime <= 0 || !now.Before(holder.ExpiresAt) {
		return 0
	}
	return min(1, float64(holder.ExpiresAt.Sub(now))/float64(lifetime))
}
