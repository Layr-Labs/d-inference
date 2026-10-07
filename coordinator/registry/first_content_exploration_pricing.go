package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"
)

// first_content_exploration_pricing.go prices a provider that evidence
// exploration admits (first_content_exploration.go). Each rate is replaced
// on its own: the fleet median applies to decode only while the provider's
// own decode evidence is missing or old, and to prefill only while its own
// isolated prefill evidence is missing or old. One served request that
// renews a rate brings back the provider's own value for that rate.

// fillExplorationRates runs once per snapshot, after the snapshot is filled.
// Caller holds p.mu.
func (r *Registry) fillExplorationRates(s *routingSnapshot, p *Provider, now time.Time) {
	if !firstContentExplorationAdmitted(s) {
		return
	}
	if s.fleetMedianTPS > 0 && forecast.ExplorationReplacesRate(s.observedDecodeTPS > 0, s.decodePerformanceAgeMs) {
		s.explorationDecodeTPS = s.fleetMedianTPS
	}
	ownPrefill := s.isolatedPrefillInitialized && capacityvalue.FinitePositive(s.isolatedPrefillTPS)
	if median := r.tpsRegistry.PrefillMedian(s.model, s.chipFamily); capacityvalue.FinitePositive(median) &&
		forecast.ExplorationReplacesRate(ownPrefill, firstContentPrefillAgeMs(p.firstContentMeasurements, s.model, now)) {
		s.explorationPrefillTPS = median
	}
}

// firstContentExplorationAdmitted is the provider-state half of
// firstContentEvidenceExplorable plus the capacity checks that come before
// the performance reasons in forecast.UnknownReason. The request-level checks
// cannot be on a snapshot. The status stays unknown.
func firstContentExplorationAdmitted(s *routingSnapshot) bool {
	return s.hasBackendCapacity && s.capacityAgeMs >= 0 &&
		time.Duration(s.capacityAgeMs)*time.Millisecond <= forecast.CapacityFreshness &&
		firstContentIdleEvidenceGap(s)
}

// firstContentPrefillAgeMs returns the age of the dated prefill measurement
// for the model. -1 means the rate is not dated. The decode age is on the
// snapshot (decodePerformanceAgeMs).
func firstContentPrefillAgeMs(history *measurements.History, model string, now time.Time) int32 {
	sample, ok := history.Lookup(model)
	if !ok || sample.ObservedAfter.IsZero() {
		return -1
	}
	return heartbeatAgeMs(now, sample.ObservedAfter)
}

// explorationUsesMedian reports whether either rate is a fleet median. The
// TTFT calibrator must not learn from such a prediction.
func (s *candidateSnapshot) explorationUsesMedian() bool {
	return s.explorationDecodeTPS > 0 || s.explorationPrefillTPS > 0
}
