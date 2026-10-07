package metrics

// Metric names (without the "d_inference." namespace prefix added by the client).
const (
	PartialSuccess        = "inference.partial_success"
	NoTerminalAfterCancel = "inference.no_terminal_after_cancel"
)

// partialSuccessTags builds the tag set for metricPartialSuccess.
func PartialSuccessTags(model, errorClass string) []string {
	return []string{"model:" + model, "error_class:" + errorClass}
}

// recordPartialSuccessCompletion emits the partial_success counter for a request
// that the provider COMPLETED (and was billed/paid for) after the consumer had
// already disconnected. Call this in addition to — never instead of — the
// existing inference.completions emit.
func (s *Reporter) PartialSuccess(model, errorClass string) {
	s.Observation.Incr(PartialSuccess, PartialSuccessTags(model, errorClass))
}

// recordNoTerminalAfterCancel emits the no-terminal-after-cancel counter: a
// post-commit disconnect whose settlement grace expired before any provider
// terminal arrived, so the reservation was refunded and no payout occurred.
func (s *Reporter) NoTerminal(model string) {
	s.Observation.Incr(NoTerminalAfterCancel, []string{"model:" + model})
}
