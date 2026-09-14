package api

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
	profiling "github.com/eigeninference/d-inference/coordinator/telemetry/profiler"
)

// Preserve the public stored-profile type names while the canonical allowlist
// and validation live together in the profiler owner.
type StoredInferenceProfile = profiling.StoredInferenceProfile
type StoredEngineProfile = profiling.StoredEngineProfile
type StoredDeadlineDecision = profiling.StoredDeadlineDecision

// retainProviderProfile hands the raw provider profile bytes to the attempt
// (size check only; decode + validation run on the profile sink worker) and
// counts the outcomes that never reach a row.
func (s *Server) retainProviderProfile(ap *registry.AttemptProfile, raw []byte) {
	if ap == nil || !s.profilerEnabled() {
		return
	}
	switch ap.SetProviderProfileRaw(raw) {
	case registry.ProviderProfileTooLarge:
		s.ddIncr("profiler.provider_profile", []string{"valid:false", "reason:size"})
	case registry.ProviderProfileDuplicate:
		s.ddIncr("profiler.provider_profile", []string{"valid:false", "reason:duplicate"})
	case registry.ProviderProfileLate:
		s.ddIncr("profiler.provider_profile", []string{"valid:false", "reason:late"})
	}
}
