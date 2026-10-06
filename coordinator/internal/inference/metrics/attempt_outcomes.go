package metrics

import (
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Attempt-level outcome + OpenRouter-view request outcome instrumentation.
//
// During the 2026-08-31 cascade the operator could not see, per model, the
// first-content kill rate or the retry amplification ratio: the only
// attempt-level series (inference.dispatches{status}) has no model tag, and
// inference.error{model,reason} collapses first-chunk kills into
// provider_error. This file adds two low-cardinality counters:
//
//   - inference.attempt_outcome{model,class} — exactly one increment per
//     dispatched attempt, at the single route-outcome funnel every terminal
//     outcome flows through (updateInferenceRouteOutcomeWithModel). class is
//     derived from the persisted final_status / error_class / error_reason, so
//     the metric and the inference_routes row cannot disagree. Kill rate is
//     first_chunk_timeout / sum(attempt_outcome); amplification is
//     sum(attempt_outcome) / sum(request_outcome), both per model.
//
//   - inference.queue_outcome{model,class} — a request that left the
//     coordinator queue WITHOUT a provider attempt being dispatched (client
//     gone, queue_deadline, queue_timeout, ttft_too_slow, tool-constraint
//     unavailable). Its route row still reaches the funnel, flagged
//     store.InferenceRouteOutcome.QueueExit by dispatchState.queuedExitOutcome,
//     and is counted here instead of on attempt_outcome: during a queue
//     incident thousands of queue expiries would otherwise inflate the
//     amplification denominator with attempts no provider ever received.
//
//   - inference.request_outcome_or_view{model,class} — the number OpenRouter
//     is intended to estimate. It keeps request_outcome's classes and adds the two
//     failure kinds request_outcome cannot see: a client that left before the
//     first token AT or PAST the upstream first-content budget (OpenRouter's
//     504) is a `timeout`, and a stream that failed after commit is
//     `mid_stream` (request_outcome counts it as success at commit time). Early
//     client aborts are tracked as the EXCLUDED class `client_gone`, so the
//     counter still fires exactly once per client request. The existing
//     request_outcome semantics are untouched.
//
// Both are mirrored on the in-process registry (GET /v1/admin/metrics) so
// they are readable without a Datadog agent.
const (
	AttemptOutcomeMetric  = "inference.attempt_outcome"
	AttemptOutcomeCounter = "inference_attempt_outcome_total"

	ORViewMetric  = "inference.request_outcome_or_view"
	ORViewCounter = "inference_request_outcome_or_view_total"

	QueueOutcomeMetric  = "inference.queue_outcome"
	QueueOutcomeCounter = "inference_queue_outcome_total"
)

// emitAttemptOutcomeMetric records one attempt_outcome increment for a
// terminal route outcome. Called from the route-outcome funnel only. A
// queue-wait exit (outcome.QueueExit) dispatched nothing and is counted on
// queue_outcome instead, so attempt_outcome stays one-per-dispatched-attempt.
func (s *Reporter) AttemptOutcome(model string, outcome *store.InferenceRouteOutcome) {
	if s == nil || outcome == nil {
		return
	}
	if outcome.QueueExit {
		s.QueueOutcome(model, outcome)
		return
	}
	class := AttemptOutcomeClass(outcome)
	if class == "" {
		return
	}
	if model == "" {
		model = "unknown"
	}
	if s.Observation.Metrics() != nil {
		s.Observation.Metrics().IncCounter(AttemptOutcomeCounter,
			observation.MetricLabel{Name: "model", Value: model}, observation.MetricLabel{Name: "class", Value: class})
	}
	if s.Observation.Datadog() == nil {
		return
	}
	s.Observation.Incr(AttemptOutcomeMetric, []string{"model:" + model, "class:" + class})
}

// emitQueueOutcomeMetric records one queue_outcome increment for the terminal
// route outcome of a queue-wait exit that never dispatched an attempt.
func (s *Reporter) QueueOutcome(model string, outcome *store.InferenceRouteOutcome) {
	class := QueueOutcomeClass(outcome)
	if s == nil || class == "" {
		return
	}
	if model == "" {
		model = "unknown"
	}
	if s.Observation.Metrics() != nil {
		s.Observation.Metrics().IncCounter(QueueOutcomeCounter,
			observation.MetricLabel{Name: "model", Value: model}, observation.MetricLabel{Name: "class", Value: class})
	}
	if s.Observation.Datadog() == nil {
		return
	}
	s.Observation.Incr(QueueOutcomeMetric, []string{"model:" + model, "class:" + class})
}

// emitCommittedRequestOutcomeORView records the OR-view outcome for a
// committed attempt's terminal route outcome. Called from the route-outcome
// funnel; no-op for pre-content terminals.
func (s *Reporter) CommittedORView(model string, outcome *store.InferenceRouteOutcome) {
	class, ok := ORViewClassForCommittedOutcome(outcome)
	if !ok {
		return
	}
	s.RecordORView(model, class)
}

// recordRequestOutcomeORView emits one request_outcome_or_view increment.
// Unlike recordRequestOutcome it carries no kv_backend tag and is scoped to
// every inference endpoint (the committed arm fires from the route-outcome
// funnel, which does not know the consumer endpoint).
func (s *Reporter) RecordORView(model, class string) {
	if s == nil || class == "" {
		return
	}
	if model == "" {
		model = "unknown"
	}
	if s.Observation.Metrics() != nil {
		s.Observation.Metrics().IncCounter(ORViewCounter,
			observation.MetricLabel{Name: "model", Value: model}, observation.MetricLabel{Name: "class", Value: class})
	}
	if s.Observation.Datadog() == nil {
		return
	}
	s.Observation.Incr(ORViewMetric, []string{"model:" + model, "class:" + class})
}
