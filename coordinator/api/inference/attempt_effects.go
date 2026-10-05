package inference

import "github.com/eigeninference/d-inference/coordinator/internal/inference/retry"

// NewAttemptEffects binds pre-content retry effects to this request owner's
// health and refund authorities, shared by direct and speculative dispatch.
func (s *Owner) NewAttemptEffects() *retry.Effects {
	return &retry.Effects{Observation: s.observation, RecordError: s.noteInferenceError, RefundExtra: s.refundProviderExtra}
}
