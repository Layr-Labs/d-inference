package inference

import "github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"

// NewInflightAbandon preserves this owner's cancellation and terminal recording
// authority when the request-absolute first-content budget runs out.
func (s *Owner) NewInflightAbandon(config attempt.TimeoutConfig) *attempt.InflightAbandon {
	return attempt.NewInflightAbandon(attempt.InflightAbandonDependencies{
		Registry: s.registry, Observation: s.observation, Routes: s.NewRouteRecorder(),
		Cancel: s.cancelDispatchForFirstContentTimeout,
	}, config)
}
