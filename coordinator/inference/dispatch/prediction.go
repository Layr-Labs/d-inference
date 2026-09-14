package dispatch

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Controller) recordPredictivePolicy(ap *registry.AttemptProfile, policy RoutePolicy, requiresVision bool) {
	bypass := registry.PredictiveBypassNone
	switch {
	case policy.Enabled:
		bypass = registry.PredictiveBypassSelfRoute
	case policy.Prefer:
		bypass = registry.PredictiveBypassPreferOwner
	case requiresVision:
		bypass = registry.PredictiveBypassMedia
	}
	ap.SetPredictivePolicy(s.deps.TTFTHardReject(), bypass)
}
