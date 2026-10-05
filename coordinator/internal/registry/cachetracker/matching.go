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

// MatchBoundaries consumes the authenticated plan and its already-derived keys.
// The controller derives keyed digests before taking its receipt mutex.
func (t *Tracker[P]) MatchBoundaries(plan cacheplan.Plan, keys []string, now time.Time) []Match[P] {
	if !t.generation.Active() {
		return nil
	}
	t.SweepIfDueLocked(now)
	out := make([]Match[P], 0)
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
				out = append(out, Match[P]{Holder: holder, Tier: tier, EvidenceWeight: cachepolicy.EvidenceWeight(holder.UpdatedAt, holder.ExpiresAt, now), queriedAt: now})
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
	t.attemptBudget.Store(0)
}
