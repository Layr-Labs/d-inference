package registry

import (
	"github.com/eigeninference/d-inference/coordinator/internal/registry/connectiontime"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"time"
)

// firstContentEvidenceGapAgeMs uses the older paired measurement's age, or
// connection age when either measurement is undated. It is not time spent idle
// or time since evidence expired. Unknown connection age returns -1.
func firstContentEvidenceGapAgeMs(s *routingSnapshot, origin *connectiontime.Origin, now time.Time) int32 {
	return forecast.EvidenceGapAgeMS(s.performanceAgeMs, origin, now)
}

// firstContentEvidenceExplorable lets idle providers compete for work that can
// renew their measurements. They remain unknown: ranking need not select them,
// and hedge/fresh-feasible requests still require qualified evidence.
func firstContentEvidenceExplorable(c *routingCandidate) bool {
	s := &c.snapshot
	return forecast.EvidenceExplorable(c.firstContent, s.modelLoaded, forecast.Workload{
		WholeMacKnown: s.wholeMacWorkKnown, WholeMacBusy: s.wholeMacBusy, PartialPrefillRows: s.partialPrefillRows,
	}, s.totalPending, s.evidenceGapAgeMs)
}

// firstContentIdleEvidenceGap is the provider-state half of
// firstContentEvidenceExplorable.
func firstContentIdleEvidenceGap(s *routingSnapshot) bool {
	return forecast.IdleEvidenceGap(s.modelLoaded, forecast.Workload{
		WholeMacKnown: s.wholeMacWorkKnown, WholeMacBusy: s.wholeMacBusy, PartialPrefillRows: s.partialPrefillRows,
	}, s.totalPending, s.evidenceGapAgeMs)
}
