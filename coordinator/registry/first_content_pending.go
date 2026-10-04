package registry

import "github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"

// recordReservedPrefill captures cache-adjusted work inside the same provider
// critical section as the memory/concurrency debit. It is owned by pendingReqs,
// so ordinary refusal, completion, cancellation and disconnect cleanup retire
// forecast work and physical reservations together.
func recordReservedPrefill(pr *PendingRequest, c *routingCandidate) {
	reserved := forecast.ReservePrefill(c.firstContent)
	pr.reservedPrefillKnown = reserved.Known
	pr.reservedPrefillTokens = reserved.Tokens
	pr.reservedPrefillRestoreMs = reserved.RestoreMS
}

func fillFirstContentPending(snap *routingSnapshot, p *Provider, model string) {
	for _, pr := range p.pendingReqs {
		if pr.reservedAt.After(snap.newestReservationAt) {
			snap.newestReservationAt = pr.reservedAt
		}
		snap.pendingPrefillRestoreMs += snap.pendingPrefill.Add(forecast.PendingPrefill{
			Reservation:           forecast.PrefillReservation{Known: pr.reservedPrefillKnown, Tokens: pr.reservedPrefillTokens, RestoreMS: pr.reservedPrefillRestoreMs},
			EstimatedPromptTokens: pr.EstimatedPromptTokens, CacheParticipates: pr.CacheRoutingParticipates(),
			ContentCommitted: pr.ContentCommittedSafe(), ModelMatches: pr.Model == model, ReservedAt: pr.reservedAt,
		}, p.CapacityAcceptedAt)
	}
}

func firstContentPrefillAhead(snap *routingSnapshot, prompt int) float64 {
	if !snap.firstContentPendingKnown {
		return queuedPrefillTokensAhead(snap, prompt)
	}
	return snap.pendingPrefill.Ahead(snap.queuedPrefillTokens, snap.queuedPrefillKnown, snap.backendWaiting, prompt)
}
