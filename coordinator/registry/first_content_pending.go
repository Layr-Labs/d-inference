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

func firstContentPrefillAhead(snap *routingSnapshot, prompt int) float64 {
	if !snap.firstContentPendingKnown {
		return queuedPrefillTokensAhead(snap, prompt)
	}
	return snap.pendingPrefill.Ahead(snap.queuedPrefillTokens, snap.queuedPrefillKnown, snap.backendWaiting, prompt)
}
