package inference

import failure "github.com/eigeninference/d-inference/coordinator/internal/inference/failure"

// metricTypedTerminal counts every provider inference_error terminal that
// carried a typed terminal_cause, tagged with the cause only (low
// cardinality: the 8 closed-vocabulary values plus "unknown"). Never tagged
// with request or provider IDs.
const metricTypedTerminal = "inference.typed_terminal"

// metricUnknownTerminalCause counts non-empty terminal_cause values outside
// the closed vocabulary — the vocabulary-drift alarm. Behavior for such
// terminals stays exactly legacy; this counter is how we notice a provider
// shipped a cause the coordinator does not understand yet.
const metricUnknownTerminalCause = "inference.typed_terminal_unknown_cause"

// noteTypedTerminalCause classifies a wire terminal_cause and emits the typed
// terminal metrics exactly once per provider error terminal (call it only
// from handleInferenceError, the single provider-frame ingress). An empty
// cause is a legacy terminal: no metric, legacy class.
func (s *Owner) noteTypedTerminalCause(cause string) failure.TerminalCauseClass {
	if cause == "" {
		return failure.CauseClassLegacy
	}
	class, known := failure.ClassifyTerminalCause(cause)
	tag := "cause:" + cause
	if !known {
		tag = "cause:unknown"
		s.observation.Incr(metricUnknownTerminalCause, nil)
	}
	s.observation.Incr(metricTypedTerminal, []string{tag})
	return class
}
