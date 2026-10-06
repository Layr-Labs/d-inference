package metrics

import (
	"net/http"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
)

const RequestOutcomeMetric = "inference.request_outcome"

// OR-uptime outcome classes (the request_outcome "class" tag). Keep this set
// low-cardinality and in sync with the dashboard formula in
// deploy/datadog/dev-network-dashboard.json.
const (
	ORSuccess     = "success"      // numerator + denominator
	ORProvider5xx = "provider_5xx" // denominator (failure)
	ORMidStream   = "mid_stream"   // denominator (failure)
	ORTimeout     = "timeout"      // denominator (failure)
	ORRateLimited = "rate_limited" // EXCLUDED (429, OpenRouter rate-limit)
	ORClientError = "client_error" // EXCLUDED (4xx client request error)
)

func IsOpenRouterScoredDispatchEndpoint(endpoint string) bool {
	return endpoint != inreq.CompletionsEndpoint && endpoint != inreq.MessagesEndpoint
}

// orUptimeClassForRejection maps a rejection's HTTP status to an OR-uptime class.
func ORUptimeClassForRejection(httpStatus int) string {
	return ClassifyOutcomeByCode(httpStatus)
}

// classifyOutcomeByCode maps an HTTP-like status to an OR-uptime class following
// OpenRouter's denominator rules (429/400/403/413 excluded; 5xx + timeouts count
// as failure). 401/402/404 are our deliberate auth/billing/not-found client
// rejections; we bucket them as client_error (excluded) rather than letting rare,
// client-caused 4xx depress the uptime we report — the formula tracks PROVIDER
// reliability. A zero/unknown code with no other signal is treated as a failure.
func ClassifyOutcomeByCode(code int) string {
	switch {
	case code == http.StatusTooManyRequests: // 429
		return ORRateLimited
	case code == http.StatusGatewayTimeout, code == http.StatusRequestTimeout: // 504, 408
		return ORTimeout
	case code >= 500:
		return ORProvider5xx
	case code >= 400:
		return ORClientError
	case code == 0:
		return ORProvider5xx
	default:
		return ORSuccess
	}
}
