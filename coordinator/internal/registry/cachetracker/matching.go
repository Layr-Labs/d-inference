package cachetracker

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
)

type Match[P comparable] struct {
	Holder         Holder[P]
	Tier           string
	EvidenceWeight float64
	queriedAt      time.Time
}

func (m Match[P]) StageCost() float64 { return m.Holder.StageCostAt(m.queriedAt) }

// MatchAt freezes a holder observation and its age weight at query time.
func (h Holder[P]) MatchAt(tier string, now time.Time) Match[P] {
	return Match[P]{Holder: h, Tier: tier, EvidenceWeight: cachepolicy.EvidenceWeight(h.UpdatedAt, h.ExpiresAt, now), queriedAt: now}
}

// MatchBoundaries consumes the authenticated plan and its already-derived keys.
// The controller derives keyed digests before taking its receipt mutex.
func (t *Tracker[P]) MatchBoundaries(plan cacheplan.Plan, keys []string, now time.Time) []Match[P] {
	if !t.generation.Active() {
		return nil
	}
	t.SweepIfDueLocked(now)
	out := make([]Match[P], 0)
	groups := cacheMatchGroups[P]{}
	for i := len(plan.Boundaries) - 1; i >= 0; i-- {
		anchor := plan.Boundaries[i]
		for _, tier := range [...]string{"ssd", "memory"} {
			key := CacheTierKey(keys[i], tier)
			for providerID := range t.holders.Entries(key) {
				holder, live := t.ActiveHolderLocked(key, providerID, now)
				if !live || holder.ModelAggregateHash != plan.ModelAggregateHash ||
					holder.PromptContractID != plan.PromptContractID || !AnchorMatches(holder.Anchor, anchor) ||
					anchor.TokenCount <= holder.RequiredRecomputeTokens {
					continue
				}
				match := holder.MatchAt(tier, now)
				if groups.exhausted || groups.retain(match, out) {
					out = append(out, match)
				}
			}
		}
	}
	return out
}

// ClearRetired drops only live indexes. Durable rows and cumulative lifecycle
// counters survive exactly as they did when the controller owned the kernels.
func (t *Tracker[P]) ClearRetired() {
	t.holders.Reset()
	t.attempts.Reset()
	t.holderOrder.Reset()
	t.attemptOrder.Reset()
	t.holdersByProvider.Reset()
	t.attemptsByProvider.Reset()
	t.v2Sequences.Reset()
	t.proofs.ClearRetired()
}
