package registry

import "time"

// addPendingPrefillToSnapshot accounts only for reservations made after the
// current capacity snapshot was applied. Their prompt estimates are available and
// they cannot already be included in that heartbeat. Older pending requests
// cannot be matched to anonymous backend counts, so retain the existing count
// fallback for those. Caller holds the owning provider's mu. Liveness-only
// heartbeat updates must never advance this boundary.
func addPendingPrefillToSnapshot(snap *routingSnapshot, pr *PendingRequest, heartbeat time.Time) {
	if heartbeat.IsZero() || !pr.reservedAt.After(heartbeat) {
		return
	}
	snap.pendingAfterHeartbeat++
	// Content ingress is per attempt, unlike the shared retry Timing pointer.
	// Once content arrived, this attempt has finished prefill even if the next
	// heartbeat has not yet reported it running. Its memory reservation remains.
	if pr.HasFirstContentIngress() {
		return
	}
	if pr.EstimatedPromptTokens > 0 {
		snap.pendingPrefillTokens += float64(pr.EstimatedPromptTokens)
	} else {
		snap.pendingPrefillUnknown++
	}
}

func queuedPrefillTokensAhead(snap *routingSnapshot, reqPromptTokens int) float64 {
	// Reconcile only older pending requests with the reported counts. New
	// reservations are separately priced above and must not be subtracted from
	// unrelated work in the older heartbeat, nor counted twice as extraPending.
	waiting := snap.backendWaiting
	reflected := snap.backendRunning + snap.backendWaiting
	olderPending := snap.pendingForModel - snap.pendingAfterHeartbeat
	if extraPending := olderPending - reflected; extraPending > 0 {
		waiting += extraPending
	}
	if reqPromptTokens < 0 {
		reqPromptTokens = 0
	}
	// A missing prompt estimate uses the legacy incoming-prompt proxy. Known
	// work still counts when the incoming prompt estimate is zero. Convert before
	// multiplying so a large count cannot overflow an integer token product.
	return snap.pendingPrefillTokens + float64(waiting+snap.pendingPrefillUnknown)*float64(reqPromptTokens)
}
