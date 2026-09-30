package registry

import "time"

// firstContentEvidenceExplorationAfter is a policy threshold, not a measured
// optimum or a service guarantee. Short gaps retain feasible-first selection.
const firstContentEvidenceExplorationAfter = 5 * time.Minute

// firstContentEvidenceGapAgeMs uses the older paired measurement's age, or
// connection age when either measurement is undated. It is not time spent idle
// or time since evidence expired. Unknown connection age returns -1.
func firstContentEvidenceGapAgeMs(s *routingSnapshot, registeredAt, now time.Time) int32 {
	if s.performanceAgeMs >= 0 {
		return s.performanceAgeMs
	}
	if registeredAt.IsZero() {
		return -1
	}
	return heartbeatAgeMs(now, registeredAt)
}

// firstContentEvidenceExplorable lets idle providers compete for work that can
// renew their measurements. They remain unknown: ranking need not select them,
// and hedge/fresh-feasible requests still require qualified evidence.
func firstContentEvidenceExplorable(c *routingCandidate) bool {
	if c.firstContent.Status != FirstContentUnknown {
		return false
	}
	switch c.firstContent.Reason {
	case "performance_age_unknown_or_stale", "performance_missing":
	default:
		return false
	}
	return firstContentIdleEvidenceGap(&c.snapshot)
}

// firstContentIdleEvidenceGap is the provider-state half of
// firstContentEvidenceExplorable. The model is loaded, the Mac is idle, and
// the evidence gap has reached the exploration bound.
func firstContentIdleEvidenceGap(s *routingSnapshot) bool {
	return s.modelLoaded && s.wholeMacWorkKnown && !s.wholeMacBusy && s.partialPrefillRows == 0 &&
		s.totalPending == 0 && s.evidenceGapAgeMs >= 0 &&
		time.Duration(s.evidenceGapAgeMs)*time.Millisecond >= firstContentEvidenceExplorationAfter
}
