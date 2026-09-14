package ingress

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// shedIfModelRejected answers a public/prefer-owner request with 429 +
// Retry-After when its requested alias or resolved build is in the operator
// reject set (EIGENINFERENCE_REJECT_MODELS). This is a deterministic
// per-model circuit breaker: it takes an unhealthy model out of rotation before
// rate-limit, reservation, or routing work, so aggregators see rate limiting
// rather than dropped/cancelled streams. Exclusive self-route bypasses the shed
// because it never falls back to the public fleet.
func (s *Controller) shedIfModelRejected(w http.ResponseWriter, r *http.Request, parsed map[string]any, policy dispatch.RoutePolicy, publicModel, model string, stream bool, estimatedPromptTokens, requestedMaxTokens int, requiresVision, hasTools bool) bool {
	if policy.Enabled || !s.deps.ModelShed(model, publicModel) {
		return false
	}
	retryAfter := s.deps.Dispatch().EstimateRetryAfter(model)
	if retryAfter <= 0 {
		retryAfter = 30
	}
	s.deps.Metrics.Incr("routing.decisions", []string{"model:" + model, "model_type:" + s.deps.Registry().ModelType(model), "outcome:model_shed"})
	s.deps.Observer.Rejection(dispatch.Rejection{
		Request:               r,
		Stage:                 "model_shed",
		ReasonCode:            "model_shed",
		HttpStatus:            http.StatusTooManyRequests,
		KeyID:                 requestcontext.KeyID(r.Context()),
		ConsumerKeyHash:       store.HashKey(requestcontext.AccountID(r.Context())),
		RequestedModel:        publicModel,
		ResolvedModel:         model,
		Stream:                stream,
		EstimatedPromptTokens: estimatedPromptTokens,
		RequestedMaxTokens:    requestedMaxTokens,
		RequiresVision:        requiresVision,
		HasTools:              hasTools,
		SelfRouteOnly:         policy.Enabled,
		PreferOwner:           policy.Prefer,
		RetryAfterMs:          retryAfter * 1000,
		Params:                rejectionSamplingParams(parsed),
	})
	w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
	httpresponse.WriteJSON(w, http.StatusTooManyRequests, httpresponse.ErrorBody("rate_limit_exceeded",
		fmt.Sprintf("model %q is temporarily rate-limited — retry after %ds", publicModel, retryAfter),
		httpresponse.WithCode("rate_limit_exceeded")))
	return true
}

// writeServiceUnavailable writes a retryable 503 with a Retry-After header so
// clients (and OpenRouter) can schedule the retry instead of blind backoff.
func (s *Controller) writeServiceUnavailable(w http.ResponseWriter, model string) {
	w.Header().Set("Retry-After", strconv.Itoa(s.deps.Dispatch().EstimateRetryAfter(model)))
	httpresponse.WriteJSON(w, http.StatusServiceUnavailable, httpresponse.ErrorBody("service_unavailable",
		"service temporarily unavailable — please retry"))
}

// rejectionSamplingParams captures only the non-content sampling knobs already
// parsed from an inbound request body for the rejection ledger. It never
// includes prompt/message/input content. Returns nil when none are present.
func rejectionSamplingParams(parsed map[string]any) json.RawMessage {
	if parsed == nil {
		return nil
	}
	knobs := make(map[string]any, 4)
	for _, k := range []string{"temperature", "top_p", "presence_penalty", "frequency_penalty"} {
		if v, ok := parsed[k]; ok {
			knobs[k] = v
		}
	}
	if len(knobs) == 0 {
		return nil
	}
	b, err := json.Marshal(knobs)
	if err != nil {
		return nil
	}
	return b
}
