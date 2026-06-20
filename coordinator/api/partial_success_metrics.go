package api

// Telemetry for the "client gone after commit" outcome family.
//
// A successful provider completion and a completion delivered after the consumer
// already disconnected are billed and credited identically — provider paid,
// consumer charged, not a provider failure — but they are NOT the same operational
// event. The clean success is a healthy request; the post-disconnect completion is
// a partial_success the operator wants to watch (it tracks client churn and the
// ~4-5% of gpt-oss traffic that completes into a dropped connection).
//
// Historically both emitted only d_inference.inference.completions{model}, so the
// partial class was invisible on dashboards. These helpers add the split WITHOUT
// changing the existing completions counter (non-breaking for current dashboards):
//
//   - d_inference.inference.partial_success{model,error_class}
//       emitted IN ADDITION to inference.completions when the consumer was gone at
//       completion time (handleComplete, consumerGone == true).
//   - d_inference.inference.no_terminal_after_cancel{model}
//       emitted when a post-commit disconnect's settlement grace expires with no
//       provider terminal (payout-gap edge): the reservation is refunded and the
//       provider is never paid for whatever it may have produced.
//
// The broad "how many clients went away, by phase" signal is NOT duplicated here:
// it lives on d_inference.routing.client_gone{model,prompt_bucket,chip_family,phase},
// which already carries both the before_first_token (pre-commit) and after_commit
// (provider terminal) phases plus prompt-size and chip dimensions.
//
// All counters go through the existing DogStatsD wrappers (ddIncr), which no-op
// when Datadog is not configured (e.g. in tests). The "d_inference." namespace is
// prepended by datadog.Client (statsd.WithNamespace).

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
func (s *Server) recordPartialSuccessCompletion(model, errorClass string) {
	s.ddIncr(metricPartialSuccess, partialSuccessTags(model, errorClass))
}

// recordNoTerminalAfterCancel emits the no-terminal-after-cancel counter: a
// post-commit disconnect whose settlement grace expired before any provider
// terminal arrived, so the reservation was refunded and no payout occurred.
func (s *Server) recordNoTerminalAfterCancel(model string) {
	s.ddIncr(metricNoTerminalAfterCancel, []string{"model:" + model})
}
