package inference

// Metric names (without the "d_inference." namespace prefix added by the client).
const (
	metricPartialSuccess        = "inference.partial_success"
	metricNoTerminalAfterCancel = "inference.no_terminal_after_cancel"
)

// errorClassClientGoneAfterCommitCompleted is the route-outcome error_class for a
// request whose consumer disconnected after commit and whose provider then
// completed (provider paid, consumer charged). It is shared by the route-outcome
// writer (completeRouteOutcome) and the partial_success metric so the wire class
// can never drift between the stored outcome and the dashboard counter.
const errorClassClientGoneAfterCommitCompleted = "client_gone_after_commit_provider_completed"

// partialSuccessTags builds the tag set for metricPartialSuccess.
func partialSuccessTags(model, errorClass string) []string {
	return []string{"model:" + model, "error_class:" + errorClass}
}

// recordPartialSuccessCompletion emits the partial_success counter for a request
// that the provider COMPLETED (and was billed/paid for) after the consumer had
// already disconnected. Call this in addition to — never instead of — the
// existing inference.completions emit.
func (s *Owner) recordPartialSuccessCompletion(model, errorClass string) {
	s.observation.Incr(metricPartialSuccess, partialSuccessTags(model, errorClass))
}

// recordNoTerminalAfterCancel emits the no-terminal-after-cancel counter: a
// post-commit disconnect whose settlement grace expired before any provider
// terminal arrived, so the reservation was refunded and no payout occurred.
func (s *Owner) recordNoTerminalAfterCancel(model string) {
	s.observation.Incr(metricNoTerminalAfterCancel, []string{"model:" + model})
}
