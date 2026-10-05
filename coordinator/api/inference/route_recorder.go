package inference

import (
	routeoutcome "github.com/eigeninference/d-inference/coordinator/internal/inference/outcome"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// NewRouteRecorder binds route reporting to this owner's real operational sinks.
func (s *Owner) NewRouteRecorder() *routeoutcome.Recorder {
	if s == nil {
		return nil
	}
	return &routeoutcome.Recorder{
		Store: s.store, Observation: s.observation, Metrics: s.NewMetrics(),
		AttemptMetric: s.NewMetrics().AttemptOutcome, CommittedMetric: s.NewMetrics().CommittedORView,
		TimingMetric: s.emitTimingDecompositionMetric, CacheTerminal: s.emitCacheSelectionTerminal,
	}
}

func (s *Owner) updateInferenceRouteOutcomeWithModel(requestID string, attempt int, model string, outcome *store.InferenceRouteOutcome) {
	s.NewRouteRecorder().Update(requestID, attempt, model, outcome)
}

func (s *Owner) updateInferenceRouteOutcomeForPending(pr *registry.PendingRequest, outcome *store.InferenceRouteOutcome) {
	s.NewRouteRecorder().Pending(pr, outcome)
}
