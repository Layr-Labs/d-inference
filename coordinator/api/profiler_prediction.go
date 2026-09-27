package api

import "github.com/eigeninference/d-inference/coordinator/registry"

func (s *Server) recordPredictivePolicy(ap *registry.AttemptProfile, policy selfRoutePolicy, requiresVision bool) {
	bypass := registry.PredictiveBypassNone
	switch {
	case policy.enabled:
		bypass = registry.PredictiveBypassSelfRoute
	case policy.prefer:
		bypass = registry.PredictiveBypassPreferOwner
	case requiresVision:
		bypass = registry.PredictiveBypassMedia
	}
	ap.SetPredictivePolicy(s.ttftHardReject, bypass)
}
