package inference

import (
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Owner) recordPredictivePolicy(ap *registry.AttemptProfile, policy selfRoutePolicy, requiresVision bool) {
	observation.RecordPredictivePolicy(ap, s.ttftHardReject, policy.enabled, policy.prefer, requiresVision)
}
