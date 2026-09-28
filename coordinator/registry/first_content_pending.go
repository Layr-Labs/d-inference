package registry

// recordReservedPrefill captures cache-adjusted work inside the same provider
// critical section as the memory/concurrency debit. It is owned by pendingReqs,
// so ordinary refusal, completion, cancellation and disconnect cleanup retire
// forecast work and physical reservations together.
func recordReservedPrefill(pr *PendingRequest, c *routingCandidate) {
	pr.reservedPrefillKnown = c.firstContent.PromptTokens > 0
	pr.reservedPrefillTokens = max(0, float64(c.firstContent.PromptTokens)-c.firstContent.CachedTokens)
	pr.reservedPrefillRestoreMs = c.firstContent.RestoreMs
}

func fillFirstContentPending(snap *routingSnapshot, p *Provider, model string) {
	for _, pr := range p.pendingReqs {
		if pr.reservedAt.After(snap.newestReservationAt) {
			snap.newestReservationAt = pr.reservedAt
		}
		if pr.Model != model || pr.ContentCommittedSafe() {
			continue
		}
		tokens, known := pr.reservedPrefillTokens, pr.reservedPrefillKnown
		if !known && pr.EstimatedPromptTokens > 0 && !pr.CacheRoutingParticipates() {
			tokens, known = float64(pr.EstimatedPromptTokens), true
		}
		// A reservation created after the latest accepted capacity frame cannot
		// already occur in that frame's queue. Earlier reservations may overlap;
		// compare their total with reported queued work rather than adding it twice.
		unreported := !p.CapacityAcceptedAt.IsZero() && !pr.reservedAt.Before(p.CapacityAcceptedAt)
		if unreported {
			if known {
				snap.unreportedPrefillTokens += tokens
			} else {
				snap.unreportedPrefillUnknown++
			}
		} else {
			if known {
				snap.overlappingPrefillTokens += tokens
			} else {
				snap.overlappingPrefillUnknown++
			}
		}
		snap.pendingPrefillRestoreMs += pr.reservedPrefillRestoreMs
	}
}

func firstContentPrefillAhead(snap *routingSnapshot, prompt int) float64 {
	if !snap.firstContentPendingKnown {
		return queuedPrefillTokensAhead(snap, prompt)
	}
	localOverlap := snap.overlappingPrefillTokens + float64(snap.overlappingPrefillUnknown)*float64(max(0, prompt))
	reported := float64(snap.backendWaiting) * float64(max(0, prompt))
	if snap.queuedPrefillKnown {
		reported = float64(snap.queuedPrefillTokens)
	}
	return max(localOverlap, reported) + snap.unreportedPrefillTokens + float64(snap.unreportedPrefillUnknown)*float64(max(0, prompt))
}
