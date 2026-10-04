package inference

import "github.com/eigeninference/d-inference/coordinator/internal/inference/metrics"

const (
	phaseBeforeFirstToken = "before_first_token"
	phaseAfterCommit      = "after_commit"
)

// NewMetrics binds the lifecycle reporter to the owner's operational sinks.
func (s *Owner) NewMetrics() *metrics.Reporter {
	if s == nil {
		return nil
	}
	return &metrics.Reporter{Observation: s.observation, Logger: s.logger}
}
