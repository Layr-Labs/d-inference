package registry

import "time"

// firstContentEvidenceExplorationAfter bounds how long an idle, loaded provider
// can be kept out of deadline-bearing routing solely because it has no current
// performance evidence. It is a policy bound, not a measured optimum: longer
// than the 2-minute performance-freshness horizon, so ordinary short idle gaps
// still rank qualified evidence first, and far shorter than the hour-scale
// exclusions observed in production when it is absent.
const firstContentEvidenceExplorationAfter = 5 * time.Minute

// firstContentEvidenceGapAgeMs is how long the snapshot's model has lacked
// usable performance evidence: the age of the dated measurement when one
// exists, otherwise the age of the connection that has not produced one.
// -1 when neither is known. It never renews or invents a measurement.
func firstContentEvidenceGapAgeMs(s *routingSnapshot, registeredAt, now time.Time) int32 {
	if s.performanceAgeMs >= 0 {
		return s.performanceAgeMs
	}
	if registeredAt.IsZero() {
		return -1
	}
	return heartbeatAgeMs(now, registeredAt)
}

// firstContentEvidenceExplorable reports an idle, loaded candidate whose
// forecast is unknown only because its performance evidence is missing or has
// aged while it had no work to measure, for longer than the exploration bound.
//
// Measurement evidence is renewed only by serving, and preferring qualified
// evidence without exception means such a provider is never served. Admitting it
// beside feasible peers lets ordinary ranking give it the request that produces
// the evidence; its forecast status stays unknown, so hedge and fresh-feasible
// requests still exclude it.
func firstContentEvidenceExplorable(c *routingCandidate) bool {
	if c.firstContent.Status != FirstContentUnknown {
		return false
	}
	switch c.firstContent.Reason {
	case "performance_age_unknown_or_stale", "performance_missing":
	default:
		return false
	}
	s := &c.snapshot
	return s.modelLoaded && s.wholeMacWorkKnown && !s.wholeMacBusy && s.partialPrefillRows == 0 &&
		s.totalPending == 0 && s.evidenceGapAgeMs >= 0 &&
		time.Duration(s.evidenceGapAgeMs)*time.Millisecond >= firstContentEvidenceExplorationAfter
}
