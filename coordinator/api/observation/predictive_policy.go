package observation

import "github.com/eigeninference/d-inference/coordinator/registry"

func RecordPredictivePolicy(ap *registry.AttemptProfile, hardReject, selfRouteOnly, preferOwner, requiresVision bool) {
	bypass := registry.PredictiveBypassNone
	switch {
	case selfRouteOnly:
		bypass = registry.PredictiveBypassSelfRoute
	case preferOwner:
		bypass = registry.PredictiveBypassPreferOwner
	case requiresVision:
		bypass = registry.PredictiveBypassMedia
	}
	ap.SetPredictivePolicy(hardReject, bypass)
}
