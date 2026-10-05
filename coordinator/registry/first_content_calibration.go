package registry

import "github.com/eigeninference/d-inference/coordinator/internal/registry/performance"

func calibrationEvidence(s *routingSnapshot) performance.CalibrationEvidence {
	evidence := performance.CalibrationEvidence{
		Work:      s.calibratedWork,
		WorkKnown: s.calibratedWorkKnown, HasCapacity: s.hasBackendCapacity,
		CapacityAgeMS: s.capacityAgeMs, ModelLoaded: s.modelLoaded,
		PromptWorkArtifactHash: s.promptWorkArtifactHash, PromptWorkContractID: s.promptWorkContractID,
		PerformanceAgeMS: s.performanceAgeMs, IsolatedPrefillTPS: s.isolatedPrefillTPS,
		IsolatedInitialized: s.isolatedPrefillInitialized, ContendedPerformanceAgeMS: s.contendedPerformanceAgeMs,
		ContendedPrefillTPS: s.contendedPrefillTPS, DecodeTPS: s.calibratedDecodeTPS,
	}
	if profile := s.deadlineProfile; profile != nil {
		evidence.Calibration, evidence.ArtifactSHA256 = profile.DeadlineCalibration, profile.ArtifactSHA256
		evidence.ConfiguredContextTokens = profile.ConfiguredContextTokens
	}
	return evidence
}
