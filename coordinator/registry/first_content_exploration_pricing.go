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
	decodeAgeMs, prefillAgeMs := firstContentRateAgesMs(p.firstContentMeasurements, s.model, now)
	if s.fleetMedianTPS > 0 && forecast.ExplorationReplacesRate(s.observedDecodeTPS > 0, decodeAgeMs) {
		s.explorationDecodeTPS = s.fleetMedianTPS
	}
	ownPrefill := s.isolatedPrefillInitialized && capacityvalue.FinitePositive(s.isolatedPrefillTPS)
	if median := r.tpsRegistry.PrefillMedian(s.model, s.chipFamily); capacityvalue.FinitePositive(median) &&
		forecast.ExplorationReplacesRate(ownPrefill, prefillAgeMs) {
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

// firstContentRateAgesMs returns the age of each dated measurement for the
// model. -1 means the rate is not dated.
func firstContentRateAgesMs(history *measurements.History, model string, now time.Time) (decodeMs, prefillMs int32) {
	decodeMs, prefillMs = -1, -1
	sample, ok := history.Lookup(model)
	if !ok {
		return decodeMs, prefillMs
	}
	if !sample.DecodeObservedAfter.IsZero() {
		decodeMs = heartbeatAgeMs(now, sample.DecodeObservedAfter)
	}
	if !sample.ObservedAfter.IsZero() {
		prefillMs = heartbeatAgeMs(now, sample.ObservedAfter)
	}
	return decodeMs, prefillMs
}

// explorationUsesMedian reports whether either rate is a fleet median. The
// TTFT calibrator must not learn from such a prediction.
func (s *candidateSnapshot) explorationUsesMedian() bool {
	return s.explorationDecodeTPS > 0 || s.explorationPrefillTPS > 0
}
