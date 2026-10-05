package inference

import "github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"

// NewWaitTimeout binds a wait's terminal claim to the same cancellation and
// provider-health owners used by settlement and the provider read loop.
func (s *Owner) NewWaitTimeout(config attempt.TimeoutConfig) *attempt.Timeout {
	return attempt.NewTimeout(attempt.TimeoutDependencies{
		Registry: s.registry, Observation: s.observation, Logger: s.logger,
		Cancel: s.cancelDispatchForFirstContentTimeout, RecordError: s.noteInferenceError,
	}, config)
}

func (d *dispatchState) newWaitTimeout() *attempt.Timeout {
	return d.s.NewWaitTimeout(attempt.TimeoutConfig{
		Model: d.model, Provider: d.provider, Pending: d.pr,
		RequestID: d.requestID, Attempt: d.attempt,
	})
}
