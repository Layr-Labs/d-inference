package api

import "net/http"

// OpenRouter-formula uptime instrumentation.
//
// OpenRouter scores a provider by uptime = successful / total, where the
// denominator EXCLUDES 429 (rate-limit), 400, 413, 403, and COUNTS as failure
// all 5xx, mid-stream errors, and fetch-timeouts. The number we are actually
// graded on therefore is:
//
//	uptime = success / (success + provider_5xx + mid_stream + timeout)
//
// To watch that number live we emit ONE counter, d_inference.inference.request_outcome,
// tagged {model, class}, exactly once per client request, at the two disjoint
// request-terminal chokepoints:
//
//   - dispatch.go run() tail — every DISPATCHED request emits exactly once:
//     committed → success (the consumer got content), exhausted → the failure
//     class derived from the final HTTP status (after the token-budget→429
//     reclassification).
//   - recordRejection (rejection_telemetry.go) — every PRE-dispatch rejection
//     (stage != "dispatch") emits exactly once from its HTTP status. The
//     dispatch-stage exhausted rejection is skipped there because run()'s tail
//     already counted it.
//
// These two sets are disjoint (a request is either dispatched or rejected before
// dispatch), so there is no double counting and no per-attempt / speculative
// inflation. A committed request that later fails mid-stream is counted as success
// (commit-time approximation); the exact post-commit breakdown is available from
// the persisted route-outcome rows (GET /v1/admin/routes, filter by final_status)
// and the rejection ledger (GET /v1/admin/rejections).
//
// Scope: dispatched-request outcomes are emitted on the /v1/chat/completions
// (+ Responses) path, which is what OpenRouter scores us on. The inline
// /v1/completions + /v1/messages path emits only its pre-dispatch rejections
// (via recordRejection); its dispatched successes/failures are not counted here.
// The classes rate_limited / client_error are tracked but EXCLUDED from the
// formula above, matching OpenRouter's denominator.

const metricRequestOutcome = "inference.request_outcome"

// OR-uptime outcome classes (the request_outcome "class" tag). Keep this set
// low-cardinality and in sync with the dashboard formula in
// deploy/datadog/dev-network-dashboard.json.
const (
	orClassSuccess     = "success"      // numerator + denominator
	orClassProvider5xx = "provider_5xx" // denominator (failure)
	orClassMidStream   = "mid_stream"   // denominator (failure)
	orClassTimeout     = "timeout"      // denominator (failure)
	orClassRateLimited = "rate_limited" // EXCLUDED (429, OpenRouter rate-limit)
	orClassClientError = "client_error" // EXCLUDED (4xx client request error)
)

// recordRequestOutcome emits the per-request OR-uptime outcome counter. model is
// normalized to "unknown" when empty (e.g. a rejection before model resolution)
// so the tag is always present for dashboard grouping. No-op when Datadog is
// unconfigured (ddIncr guards nil).
func (s *Server) recordRequestOutcome(model, class string) {
	if model == "" {
		model = "unknown"
	}
	s.ddIncr(metricRequestOutcome, []string{"model:" + model, "class:" + class})
}

// orUptimeClassForRejection maps a rejection's HTTP status to an OR-uptime class.
func orUptimeClassForRejection(httpStatus int) string {
	return classifyOutcomeByCode(httpStatus)
}

// classifyOutcomeByCode maps an HTTP-like status to an OR-uptime class following
// OpenRouter's denominator rules (429/400/403/413 excluded; 5xx + timeouts count
// as failure). 401/402/404 are our deliberate auth/billing/not-found client
// rejections; we bucket them as client_error (excluded) rather than letting rare,
// client-caused 4xx depress the uptime we report — the formula tracks PROVIDER
// reliability. A zero/unknown code with no other signal is treated as a failure.
func classifyOutcomeByCode(code int) string {
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
		return orClassSuccess
	}
}
