package api

import (
	"strings"

	"github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
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
	metricAttemptOutcome        = "inference.attempt_outcome"
	metricAttemptOutcomeCounter = "inference_attempt_outcome_total"

	metricRequestOutcomeORView        = "inference.request_outcome_or_view"
	metricRequestOutcomeORViewCounter = "inference_request_outcome_or_view_total"

	metricQueueOutcome        = "inference.queue_outcome"
	metricQueueOutcomeCounter = "inference_queue_outcome_total"
)

// attempt_outcome classes. A fixed vocabulary: anything the mapping does not
// recognise lands in `other` rather than minting a new tag value.
const (
	attemptClassSuccess             = "success"
	attemptClassFirstChunkTimeout   = "first_chunk_timeout"
	attemptClassDeadlineUnreachable = "deadline_unreachable"
	attemptClassCapacity            = "capacity"
	attemptClassClientError         = "client_error"
	attemptClassFault               = "fault"
	attemptClassSendFailed          = "send_failed"
	attemptClassDisconnect          = "disconnect"
	attemptClassClientGone          = "client_gone"
	attemptClassSpeculativeLoser    = "speculative_loser"
	attemptClassOther               = "other"
)

// queue_outcome classes: the queue-wait exits that never dispatched an attempt
// (dispatchState.queuedExitOutcome), keyed by the error_class those exits
// persist. A fixed vocabulary: anything else lands in `other`.
const (
	queueClassClientGone            = "client_gone"
	queueClassQueueDeadline         = dispatch.RejectionReasonQueueDeadline
	queueClassQueueTimeout          = "queue_timeout"
	queueClassTTFTTooSlow           = "ttft_too_slow"
	queueClassCapabilityUnsupported = "model_capability_unsupported"
	queueClassOther                 = "other"
)

// isCapacityClassErrorReason reports whether a persisted error_reason names a
// capacity / admission condition (the provider is healthy but full, the
// request cannot fit, or the provider is draining ahead of a restart and
// refusing new work — routing counts that as transient capacity too) rather
// than a fault.
func isCapacityClassErrorReason(reason string) bool {
	switch attempt.NormalizeInferenceErrorReason(reason) {
	case attempt.ErrorReasonCapacityBusy, attempt.ErrorReasonCapacityTimeout, attempt.ErrorReasonQueueFull,
		attempt.ErrorReasonTokenBudgetExhaust, attempt.ErrorReasonRequestExceedsContext,
		attempt.ErrorReasonRequestExceedsNode, attempt.ErrorReasonRequestExceedsNodeBudget,
		attempt.ErrorReasonRequestExceedsBatchBudget, attempt.ErrorReasonModelLoad,
		attempt.ErrorReasonDraining:
		return true
	default:
		return false
	}
}

// attemptOutcomeClass maps a TERMINAL route outcome to its attempt_outcome
// class. Returns "" for a non-terminal (commit-time pre-fill) outcome, which
// must not be counted. partial_success is an attempt that DID deliver first
// content (the ladder succeeded); its post-commit failure is measured on
// inference.in_band_error and request_outcome_or_view{mid_stream}, not here.
func attemptOutcomeClass(outcome *store.InferenceRouteOutcome) string {
	if outcome == nil {
		return ""
	}
	status := strings.ToLower(strings.TrimSpace(outcome.FinalStatus))
	class := strings.ToLower(strings.TrimSpace(outcome.ErrorClass))
	switch status {
	case "":
		return ""
	case attempt.FinalStatusSuccess, attempt.FinalStatusPartialSuccess:
		return attemptClassSuccess
	case attempt.FinalStatusCancelled:
		if class == "speculative_loser" {
			return attemptClassSpeculativeLoser
		}
		return attemptClassClientGone
	case attempt.FinalStatusTimeout:
		// Queue expiries never dispatched to a provider: they are fleet
		// capacity, not a first-content kill, and must not inflate the
		// per-model kill rate the alert sketch keys on.
		if class == "queue_timeout" || class == "queue_deadline" {
			return attemptClassCapacity
		}
		return attemptClassFirstChunkTimeout
	case attempt.FinalStatusError:
		return attemptErrorOutcomeClass(class, outcome)
	default:
		return attemptClassOther
	}
}

func attemptErrorOutcomeClass(class string, outcome *store.InferenceRouteOutcome) string {
	switch class {
	case "first_chunk_timeout":
		return attemptClassFirstChunkTimeout
	case attempt.ErrorClassDeadlineUnreachable:
		return attemptClassDeadlineUnreachable
	case attempt.ErrorClassClientError:
		return attemptClassClientError
	case "provider_disconnect_pre_commit", "provider_disconnect_before_response":
		return attemptClassDisconnect
	case "ttft_too_slow", "queue_timeout", attempt.ErrorReasonQueueFull:
		return attemptClassCapacity
	}
	if isCapacityClassErrorReason(outcome.ErrorReason) {
		return attemptClassCapacity
	}
	switch class {
	case attempt.ErrorReasonProviderError:
		// providerFailedRoutingOutcomeFor stamps AdmittedButFailed on every
		// provider-executed failure; a bare provider_error row without it is a
		// coordinator-side dispatch failure ("failed to send request to
		// provider", request preparation) — the attempt never reached the engine.
		if !outcome.AdmittedButFailed {
			return attemptClassSendFailed
		}
		return attemptClassFault
	case "provider_error_before_response", "provider_incomplete_before_response":
		return attemptClassFault
	}
	return attemptClassOther
}

// queueOutcomeClass maps the terminal outcome of a queue-wait exit (an
// outcome flagged QueueExit) to its queue_outcome class. Returns "" for a
// non-terminal outcome, which must not be counted.
func queueOutcomeClass(outcome *store.InferenceRouteOutcome) string {
	if outcome == nil || strings.TrimSpace(outcome.FinalStatus) == "" {
		return ""
	}
	switch class := strings.ToLower(strings.TrimSpace(outcome.ErrorClass)); class {
	case queueClassClientGone, queueClassQueueDeadline, queueClassQueueTimeout,
		queueClassTTFTTooSlow, queueClassCapabilityUnsupported:
		return class
	default:
		return queueClassOther
	}
}

// emitAttemptOutcomeMetric records one attempt_outcome increment for a
// terminal route outcome. Called from the route-outcome funnel only. A
// queue-wait exit (outcome.QueueExit) dispatched nothing and is counted on
// queue_outcome instead, so attempt_outcome stays one-per-dispatched-attempt.
func (s *Server) emitAttemptOutcomeMetric(model string, outcome *store.InferenceRouteOutcome) {
	if s == nil || outcome == nil {
		return
	}
	if outcome.QueueExit {
		s.emitQueueOutcomeMetric(model, outcome)
		return
	}
	class := attemptOutcomeClass(outcome)
	if class == "" {
		return
	}
	if model == "" {
		model = "unknown"
	}
	if s.metrics != nil {
		s.metrics.IncCounter(metricAttemptOutcomeCounter,
			MetricLabel{Name: "model", Value: model}, MetricLabel{Name: "class", Value: class})
	}
	if s.dd == nil {
		return
	}
	s.ddIncr(metricAttemptOutcome, []string{"model:" + model, "class:" + class})
}

// emitQueueOutcomeMetric records one queue_outcome increment for the terminal
// route outcome of a queue-wait exit that never dispatched an attempt.
func (s *Server) emitQueueOutcomeMetric(model string, outcome *store.InferenceRouteOutcome) {
	class := queueOutcomeClass(outcome)
	if s == nil || class == "" {
		return
	}
	if model == "" {
		model = "unknown"
	}
	if s.metrics != nil {
		s.metrics.IncCounter(metricQueueOutcomeCounter,
			MetricLabel{Name: "model", Value: model}, MetricLabel{Name: "class", Value: class})
	}
	if s.dd == nil {
		return
	}
	s.ddIncr(metricQueueOutcome, []string{"model:" + model, "class:" + class})
}

// orViewClassForCommittedOutcome maps the terminal outcome of a COMMITTED
// attempt (the request delivered first content) to its OR-view class. ok is
// false for pre-content terminals, which are counted at the exhausted ladder /
// client-gone arms instead.
func orViewClassForCommittedOutcome(outcome *store.InferenceRouteOutcome) (class string, ok bool) {
	if outcome == nil {
		return "", false
	}
	switch strings.ToLower(strings.TrimSpace(outcome.FinalStatus)) {
	case attempt.FinalStatusSuccess:
		return dispatch.OrClassSuccess, true
	case attempt.FinalStatusPartialSuccess:
		errClass := strings.ToLower(strings.TrimSpace(outcome.ErrorClass))
		if strings.HasPrefix(errClass, "client_gone_after_commit") || errClass == "no_terminal_after_cancel" {
			// The consumer left after content had flowed: the upstream is the
			// one that hung up, so it is not graded against us.
			return dispatch.OrClassClientGone, true
		}
		// provider_error/disconnect/incomplete_after_commit, stream_timeout_after_commit.
		return dispatch.OrClassMidStream, true
	default:
		return "", false
	}
}

// emitCommittedRequestOutcomeORView records the OR-view outcome for a
// committed attempt's terminal route outcome. Called from the route-outcome
// funnel; no-op for pre-content terminals.
func (s *Server) emitCommittedRequestOutcomeORView(model string, outcome *store.InferenceRouteOutcome) {
	class, ok := orViewClassForCommittedOutcome(outcome)
	if !ok {
		return
	}
	s.recordRequestOutcomeORView(model, class)
}

// recordRequestOutcomeORView emits one request_outcome_or_view increment.
// Unlike recordRequestOutcome it carries no kv_backend tag and is scoped to
// every inference endpoint (the committed arm fires from the route-outcome
// funnel, which does not know the consumer endpoint).
func (s *Server) recordRequestOutcomeORView(model, class string) {
	if s == nil || class == "" {
		return
	}
	if model == "" {
		model = "unknown"
	}
	if s.metrics != nil {
		s.metrics.IncCounter(metricRequestOutcomeORViewCounter,
			MetricLabel{Name: "model", Value: model}, MetricLabel{Name: "class", Value: class})
	}
	if s.dd == nil {
		return
	}
	s.ddIncr(metricRequestOutcomeORView, []string{"model:" + model, "class:" + class})
}
