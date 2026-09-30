package registry

import "time"

// first_content_exploration_pricing.go prices a provider that evidence
// exploration admits (first_content_exploration.go). Each rate is replaced
// on its own: the fleet median applies to decode only while the provider's
// own decode evidence is missing or old, and to prefill only while its own
// isolated prefill evidence is missing or old. One served request that
// renews a rate brings back the provider's own value for that rate.

// firstContentExplorationAdmitted is computed once per snapshot, after the
// snapshot is filled. It is the provider-state half of
// firstContentEvidenceExplorable plus the capacity checks that come before
// the performance reasons in firstContentForecastUnknownReason. The
// request-level checks cannot be on a snapshot. The status stays unknown.
func firstContentExplorationAdmitted(s *routingSnapshot) bool {
	return s.hasBackendCapacity && s.capacityAgeMs >= 0 &&
		time.Duration(s.capacityAgeMs)*time.Millisecond <= firstContentFreshness &&
		firstContentIdleEvidenceGap(s)
}

// firstContentRateAgesMs returns the age of each dated measurement for the
// model. -1 means the rate is not dated.
func firstContentRateAgesMs(p *Provider, model string, now time.Time) (decodeMs, prefillMs int32) {
	decodeMs, prefillMs = -1, -1
	sample, ok := p.firstContentMeasurements[model]
	if !ok {
		return decodeMs, prefillMs
	}
	if !sample.decodeObservedAfter.IsZero() {
		decodeMs = heartbeatAgeMs(now, sample.decodeObservedAfter)
	}
	if !sample.observedAfter.IsZero() {
		prefillMs = heartbeatAgeMs(now, sample.observedAfter)
	}
	return decodeMs, prefillMs
}

// explorationReplacesRate reports whether an admitted provider's own rate
// gives way to the fleet median. The rate gives way when it is missing, or
// when it is dated and at least firstContentEvidenceExplorationAfter old. An
// undated rate is the first value after the provider connected, for example
// the legacy EWMA from its first served request, so it counts as its own
// evidence.
func explorationReplacesRate(present bool, ageMs int32) bool {
	return !present || (ageMs >= 0 && time.Duration(ageMs)*time.Millisecond >= firstContentEvidenceExplorationAfter)
}

// explorationUsesDecodeMedian reports whether resolveEffectiveTPS uses the
// fleet decode median for this snapshot.
func explorationUsesDecodeMedian(s *routingSnapshot) bool {
	return s.explorationAdmitted && s.fleetMedianTPS > 0 &&
		explorationReplacesRate(s.observedDecodeTPS > 0, s.decodeEvidenceAgeMs)
}

// explorationUsesPrefillMedian reports whether resolvePrefillTPS uses the
// fleet isolated prefill median for this snapshot.
func explorationUsesPrefillMedian(s *routingSnapshot) bool {
	return s.explorationAdmitted && finitePositive(s.fleetMedianPrefillTPS) &&
		explorationReplacesRate(s.isolatedPrefillInitialized && finitePositive(s.isolatedPrefillTPS), s.prefillEvidenceAgeMs)
}

// explorationUsesMedian reports whether either rate is a fleet median. The
// TTFT calibrator must not learn from such a prediction.
func explorationUsesMedian(s *routingSnapshot) bool {
	return explorationUsesDecodeMedian(s) || explorationUsesPrefillMedian(s)
}
