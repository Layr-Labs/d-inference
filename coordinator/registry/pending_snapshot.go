package registry

import (
	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/kvbudget"
)

// fillSnapshotPendingAndPool is also used by capacity publication, which needs
// memory commitments without constructing first-content work. All-model pending
// bytes use each resident model's KV rate, or the same bounded conservative cold
// rate as admission; only unreconstructable legacy pools leave bytes unknown.
// The per-model pending pair remains separate from those all-model totals.
// Caller holds p.mu.
func fillSnapshotPendingAndPool(snap *routingSnapshot, p *Provider, model string) {
	fillPendingSnapshot(snap, p, model, nil)
}

// fillPendingSnapshot reconciles pending memory and first-content work in one
// walk. A non-nil work buffer freezes each attempt's content state once for this
// routing snapshot; its bounded service inputs never retain the request owner.
// The caller owns the buffer and holds p.mu throughout projection and use.
func fillPendingSnapshot(snap *routingSnapshot, p *Provider, model string, work []forecast.PendingWork) []forecast.PendingWork {
	snap.pendingPrefillKnown = true
	if p.BackendCapacity != nil {
		snap.pooledTokenBudget = kvbudget.FromSlots(p.BackendCapacity.Slots)
	}
	pending := kvbudget.NewPending(&snap.pooledTokenBudget)
	pending.Tokens = snap.pendingMaxTokensAllModels
	pending.Bytes = snap.pendingMaxBytesAllModels
	for _, pr := range p.pendingReqs {
		var contentCommitted, cacheParticipates bool
		if work != nil {
			item := firstContentPendingWork(pr)
			work = append(work, item)
			contentCommitted, cacheParticipates = item.ContentCommitted, pr.CacheRoutingParticipates()
			if item.ReservedAt.After(snap.newestReservationAt) {
				snap.newestReservationAt = item.ReservedAt
			}
			snap.pendingPrefillRestoreMs += snap.pendingPrefill.Add(forecast.PendingPrefill{
				Reservation:           forecast.PrefillReservation{Known: item.ReservedPrefillKnown, Tokens: item.ReservedPrefillTokens, RestoreMS: item.ReservedPrefillRestoreMS},
				EstimatedPromptTokens: item.EstimatedPromptTokens, CacheParticipates: cacheParticipates,
				ContentCommitted: contentCommitted, ModelMatches: item.Model == model, ReservedAt: item.ReservedAt,
			}, p.CapacityAcceptedAt)
		}
		tokens := pendingTokenBudget(pr)
		pending.Add(&snap.pooledTokenBudget, pr.Model, tokens)
		if pr.Model != model {
			continue
		}
		snap.pendingForModel++
		snap.pendingMaxTokens += tokens
		if work == nil {
			contentCommitted, cacheParticipates = pr.ContentCommittedSafe(), pr.CacheRoutingParticipates()
		}
		if !contentCommitted {
			if pr.EstimatedPromptTokens > 0 && !cacheParticipates {
				snap.pendingPrefillTokens += float64(pr.EstimatedPromptTokens)
			} else {
				snap.pendingPrefillUnknown++
			}
		}
	}
	snap.pendingMaxTokensAllModels = pending.Tokens
	snap.pendingMaxBytesAllModels = pending.Bytes
	snap.pendingBytesKnown = pending.BytesKnown
	return work
}
