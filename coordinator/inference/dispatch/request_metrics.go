package dispatch

import (
	"math"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/inference/response"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// deadline_bucket tag values on routing.client_gone: elapsed time at the
// cancel relative to the request's first-content budget (d.deadline, the
// coordinator-side mirror of the upstream first-content deadline).
const (
	deadlineBucketUnderHalf     = "under_half"     // < 0.5 x budget: application abort
	deadlineBucketMid           = "mid"            // 0.5 .. 0.8 x budget
	deadlineBucketNearDeadline  = "near_deadline"  // >= 0.8 x budget: upstream was about to time out
	deadlineBucketOver          = "over"           // >= budget: upstream already timed out (its 504)
	DeadlineBucketUnknown       = "unknown"        // no request clock on this dispatch
	DeadlineBucketNotApplicable = "not_applicable" // after-commit phase: the budget was met
)

// DeadlineBucket buckets a pre-content client cancel by how much of the
// first-content budget had elapsed when the client left.
func DeadlineBucket(elapsed, budget time.Duration) string {
	if budget <= 0 || elapsed < 0 {
		return DeadlineBucketUnknown
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
		return OrClassClientGone
	}
}

// clientGoneDeadlineBucket is the deadline bucket for a pre-content cancel on
// this dispatch, measured on the request clock (ReceivedAt + deadline).
func (d *execution) clientGoneDeadlineBucket() string {
	if d == nil || d.timing == nil || d.timing.ReceivedAt.IsZero() || d.deadline <= 0 {
		return DeadlineBucketUnknown
	}
	return DeadlineBucket(time.Since(d.timing.ReceivedAt), d.deadline)
}

func (d *execution) recordRequestOutcomeORView(class string) {
	if d == nil {
		return
	}
	d.s.deps.Observer.RequestOutcomeORView(d.model, class)
}

// metricRouteLatency is the per-request scheduler selection latency
// (reserve → routed) sampled at attempt-0 selection time, so routing distress
// is visible while requests are still in flight rather than only at their
// terminal (inference.timing.route_ms). Queued requests are skipped: their
// RoutedAt includes the queue wait, which the request_queue gauges cover.
const metricRouteLatency = "routing.route_latency_ms"

// emitRouteLatency records the attempt-0 route segment. Called once the
// primary attempt's provider is selected (RoutedAt stamped).
func (d *execution) emitRouteLatency() {
	if d == nil || d.s == nil || !d.s.deps.Counters.Enabled() || d.attempt != 0 || d.timing == nil {
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
	d.s.deps.Counters.Histogram(metricRouteLatency, ms, []string{"model:" + d.model})
}

func (d *execution) recordDispatchedRequestOutcome(attr KVBackendAttribution, class string) {
	if d == nil || !isOpenRouterScoredDispatchEndpoint(d.consumerEndpoint) {
		return
	}
	d.s.deps.Observer.RequestOutcome(d.model, attr, class)
}

func isOpenRouterScoredDispatchEndpoint(endpoint string) bool {
	return endpoint != response.CompletionsEndpoint && endpoint != response.MessagesEndpoint
}

// ClassifyOutcomeByCode maps an HTTP-like status to an OR-uptime class following
// OpenRouter's denominator rules (429/400/403/413 excluded; 5xx + timeouts count
// as failure). 401/402/404 are our deliberate auth/billing/not-found client
// rejections; we bucket them as client_error (excluded) rather than letting rare,
// client-caused 4xx depress the uptime we report — the formula tracks PROVIDER
// reliability. A zero/unknown code with no other signal is treated as a failure.
func ClassifyOutcomeByCode(code int) string {
	switch {
	case code == http.StatusTooManyRequests: // 429
		return orClassRateLimited
	case code == http.StatusGatewayTimeout, code == http.StatusRequestTimeout: // 504, 408
		return orClassTimeout
	case code >= 500:
		return orClassProvider5xx
	case code >= 400:
		return orClassClientError
	case code == 0:
		return orClassProvider5xx
	default:
		return OrClassSuccess
	}
}

// OR-uptime outcome classes (the request_outcome "class" tag). Keep this set
// low-cardinality and in sync with the dashboard formula in
// deploy/datadog/dev-network-dashboard.json.
const (
	OrClassSuccess     = "success"      // numerator + denominator
	orClassProvider5xx = "provider_5xx" // denominator (failure)
	OrClassMidStream   = "mid_stream"   // denominator (failure)
	orClassTimeout     = "timeout"      // denominator (failure)
	orClassRateLimited = "rate_limited" // EXCLUDED (429, OpenRouter rate-limit)
	orClassClientError = "client_error" // EXCLUDED (4xx client request error)
)

// OrClassClientGone is the OR-view class for a client that left before the
// first token well inside the upstream budget (an application abort, not our
// slowness) and for post-commit client disconnects. EXCLUDED from the uptime
// formula, like rate_limited / client_error.
const OrClassClientGone = "client_gone"

// ProviderChipFamily reads a provider's hardware chip family under its lock,
// returning "" for a nil provider. Best-effort: the value feeds a metric tag only.
func ProviderChipFamily(p *registry.Provider) string {
	if p == nil {
		return ""
	}
	p.Mu().Lock()
	defer p.Mu().Unlock()
	return p.Hardware.ChipFamily
}

// client_gone phase tags. before_first_token is the prefill window (the request
// was cancelled before any content token committed); after_commit is a disconnect
// once streaming had already started (provider completed/errored with no reader).
const (
	phaseBeforeFirstToken = "before_first_token"
	PhaseAfterCommit      = "after_commit"
)
