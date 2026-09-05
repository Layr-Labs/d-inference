package api

import (
	"math"
	"strings"
	"time"

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
	queueClassQueueDeadline         = rejectionReasonQueueDeadline
	queueClassQueueTimeout          = "queue_timeout"
	queueClassTTFTTooSlow           = "ttft_too_slow"
	queueClassCapabilityUnsupported = "model_capability_unsupported"
	queueClassOther                 = "other"
)

// orClassClientGone is the OR-view class for a client that left before the
// first token well inside the upstream budget (an application abort, not our
// slowness) and for post-commit client disconnects. EXCLUDED from the uptime
// formula, like rate_limited / client_error.
const orClassClientGone = "client_gone"

// deadline_bucket tag values on routing.client_gone: elapsed time at the
// cancel relative to the request's first-content budget (d.deadline, the
// coordinator-side mirror of the upstream first-content deadline).
const (
	deadlineBucketUnderHalf     = "under_half"     // < 0.5 x budget: application abort
	deadlineBucketMid           = "mid"            // 0.5 .. 0.8 x budget
	deadlineBucketNearDeadline  = "near_deadline"  // >= 0.8 x budget: upstream was about to time out
	deadlineBucketOver          = "over"           // >= budget: upstream already timed out (its 504)
	deadlineBucketUnknown       = "unknown"        // no request clock on this dispatch
	deadlineBucketNotApplicable = "not_applicable" // after-commit phase: the budget was met
)

// isCapacityClassErrorReason reports whether a persisted error_reason names a
// capacity / admission condition (the provider is healthy but full, the
// request cannot fit, or the provider is draining ahead of a restart and
// refusing new work — routing counts that as transient capacity too) rather
// than a fault.
func isCapacityClassErrorReason(reason string) bool {
	switch normalizeInferenceErrorReason(reason) {
	case errorReasonCapacityBusy, errorReasonCapacityTimeout, errorReasonQueueFull,
		errorReasonTokenBudgetExhaust, errorReasonRequestExceedsContext,
		errorReasonRequestExceedsNode, errorReasonRequestExceedsNodeBudget,
		errorReasonRequestExceedsBatchBudget, errorReasonModelLoad,
		errorReasonDraining:
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
	case finalStatusSuccess, finalStatusPartialSuccess:
		return attemptClassSuccess
	case finalStatusCancelled:
		if class == "speculative_loser" {
			return attemptClassSpeculativeLoser
		}
		return attemptClassClientGone
	case finalStatusTimeout:
		// Queue expiries never dispatched to a provider: they are fleet
		// capacity, not a first-content kill, and must not inflate the
		// per-model kill rate the alert sketch keys on.
		if class == "queue_timeout" || class == "queue_deadline" {
			return attemptClassCapacity
		}
		return attemptClassFirstChunkTimeout
	case finalStatusError:
		return attemptErrorOutcomeClass(class, outcome)
	default:
		return attemptClassOther
	}
}

func attemptErrorOutcomeClass(class string, outcome *store.InferenceRouteOutcome) string {
	switch class {
	case "first_chunk_timeout":
		return attemptClassFirstChunkTimeout
	case errorClassDeadlineUnreachable:
		return attemptClassDeadlineUnreachable
	case errorClassClientError:
		return attemptClassClientError
	case "provider_disconnect_pre_commit", "provider_disconnect_before_response":
		return attemptClassDisconnect
	case "ttft_too_slow", "queue_timeout", errorReasonQueueFull:
		return attemptClassCapacity
	}
	if isCapacityClassErrorReason(outcome.ErrorReason) {
		return attemptClassCapacity
	}
	switch class {
	case errorReasonProviderError:
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
			MetricLabel{"model", model}, MetricLabel{"class", class})
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
			MetricLabel{"model", model}, MetricLabel{"class", class})
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
	case finalStatusSuccess:
		return orClassSuccess, true
	case finalStatusPartialSuccess:
		errClass := strings.ToLower(strings.TrimSpace(outcome.ErrorClass))
		if strings.HasPrefix(errClass, "client_gone_after_commit") || errClass == "no_terminal_after_cancel" {
			// The consumer left after content had flowed: the upstream is the
			// one that hung up, so it is not graded against us.
			return orClassClientGone, true
		}
		// provider_error/disconnect/incomplete_after_commit, stream_timeout_after_commit.
		return orClassMidStream, true
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
			MetricLabel{"model", model}, MetricLabel{"class", class})
	}
	if s.dd == nil {
		return
	}
	s.ddIncr(metricRequestOutcomeORView, []string{"model:" + model, "class:" + class})
}

// deadlineBucket buckets a pre-content client cancel by how much of the
// first-content budget had elapsed when the client left.
func deadlineBucket(elapsed, budget time.Duration) string {
	if budget <= 0 || elapsed < 0 {
		return deadlineBucketUnknown
	}
	ratio := float64(elapsed) / float64(budget)
	switch {
	case ratio < 0.5:
		return deadlineBucketUnderHalf
	case ratio < 0.8:
		return deadlineBucketMid
	case ratio < 1.0:
		return deadlineBucketNearDeadline
	default:
		return deadlineBucketOver
	}
}

// orViewClassForClientGone maps a pre-content client-gone deadline bucket to
// the OR-view class: at or past ~the upstream budget the upstream timed out on
// us (its 504 → timeout); earlier is an application abort (excluded).
func orViewClassForClientGone(bucket string) string {
	switch bucket {
	case deadlineBucketNearDeadline, deadlineBucketOver:
		return orClassTimeout
	default:
		return orClassClientGone
	}
}

// clientGoneDeadlineBucket is the deadline bucket for a pre-content cancel on
// this dispatch, measured on the request clock (ReceivedAt + deadline).
func (d *dispatchState) clientGoneDeadlineBucket() string {
	if d == nil || d.timing == nil || d.timing.ReceivedAt.IsZero() || d.deadline <= 0 {
		return deadlineBucketUnknown
	}
	return deadlineBucket(time.Since(d.timing.ReceivedAt), d.deadline)
}

func (d *dispatchState) recordRequestOutcomeORView(class string) {
	if d == nil {
		return
	}
	d.s.recordRequestOutcomeORView(d.model, class)
}

// metricRouteLatency is the per-request scheduler selection latency
// (reserve → routed) sampled at attempt-0 selection time, so routing distress
// is visible while requests are still in flight rather than only at their
// terminal (inference.timing.route_ms). Queued requests are skipped: their
// RoutedAt includes the queue wait, which the request_queue gauges cover.
const metricRouteLatency = "routing.route_latency_ms"

// emitRouteLatency records the attempt-0 route segment. Called once the
// primary attempt's provider is selected (RoutedAt stamped).
func (d *dispatchState) emitRouteLatency() {
	if d == nil || d.s == nil || d.s.dd == nil || d.attempt != 0 || d.timing == nil {
		return
	}
	t := d.timing
	if !t.QueuedAt.IsZero() || t.RoutedAt.IsZero() {
		return
	}
	anchor := t.ReservedAt
	if !t.MediaFetchedAt.IsZero() {
		anchor = t.MediaFetchedAt
	}
	if anchor.IsZero() || t.RoutedAt.Before(anchor) {
		return
	}
	// Fractional milliseconds: a healthy scan takes well under 1ms, and the
	// signal this series exists for is that floor rising toward seconds, so
	// sub-millisecond samples must not be truncated to 0 and dropped.
	ms := float64(t.RoutedAt.Sub(anchor)) / float64(time.Millisecond)
	if ms < 0 || math.IsNaN(ms) || math.IsInf(ms, 0) {
		return
	}
	d.s.ddHistogram(metricRouteLatency, ms, []string{"model:" + d.model})
}
