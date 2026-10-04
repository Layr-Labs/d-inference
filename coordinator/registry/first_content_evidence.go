package registry

import "github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"

// Capture only forecast inputs, never physical admission or mutable owners.
func firstContentForecastEvidence(s *routingSnapshot, prompt int) forecast.Evidence {
	load := s.modelLoadMs
	if !s.modelLoaded && load <= 0 {
		load, _ = slotStatePenalty(s.slotState)
	}
	return forecast.Evidence{
		Calibration: calibrationEvidence(s), CapacityAcceptedAt: s.capacityAcceptedAt,
		ObservedDecodeTPS: s.observedDecodeTPS,
		PrefillTPS:        resolvePrefillTPS(s), DecodeTPS: resolveEffectiveTPS(s), LoadFactor: effectiveTPSLoadFactor,
		WorkloadRates: s.prefillWorkloadRates,
		Transport:     forecast.Transport{ExpectedMS: s.transportMs, ConservativeMS: s.conservativeTransportMs, AgeMS: s.transportAgeMs},
		Workload: forecast.Workload{
			PrefillAhead: firstContentPrefillAhead(s, prompt), PendingRestoreMS: s.pendingPrefillRestoreMs,
			ModelLoadMS: load, ServiceMS: s.wholeMacServiceMs, OtherModelOccupancy: s.otherModelOccupancy,
			PartialPrefillRows: s.partialPrefillRows, WholeMacKnown: s.wholeMacWorkKnown, WholeMacBusy: s.wholeMacBusy,
		},
	}
}
