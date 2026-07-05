package api

import (
	"fmt"
	"net/http"
	"strconv"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Smart early-429 admission (consumer request-path glue).
//
// This is the proactive half of the fix: before admitting/dispatching a public
// request, ask the registry whether the fleet could STRUCTURALLY serve a request
// of this size (prompt + max_tokens vs the model context window and the largest
// provider token budget). When it confidently cannot, return an uptime-neutral
// 429 + Retry-After so OpenRouter fails over, instead of admitting it and letting
// the provider 5xx (the uptime-damaging "admitted_but_failed" path).
//
// It is gated behind s.servabilityGate (default off) and is fail-open by
// construction (PredictServable only rejects clearly-unservable requests). The
// always-on reclassification of an actual provider token-budget 5xx → 429 lives
// on the dispatch-exhausted path (see classifyInferenceFailure / dispatch.go).

// shedIfUnservable returns true when it has fully handled the request by writing
// an early 429 (the caller must then return). It is a no-op (returns false) when
// the gate is disabled or the request is servable. refundReservation releases any
// pre-flight balance reservation; it is invoked only on the reject path.
func (s *Server) shedIfUnservable(
	w http.ResponseWriter,
	r *http.Request,
	parsed map[string]any,
	publicModel, model string,
	modelMaxContext int,
	stream bool,
	estimatedPromptTokens, requestedMaxTokens int,
	requiresVision, hasTools bool,
	allowedProviderSerials []string,
	refundReservation func(),
) bool {
	if s == nil || !s.servabilityGate || s.registry == nil {
		return false
	}

	// The context tier gets a CALIBRATED prompt estimate; the token-budget tier
	// keeps the RAW estimate (see PredictServable). estimatePromptTokens uses
	// len/4, which UNDERcounts real tokenization (observed prod actual/estimate
	// p50 1.19, heavy right tail to ~5.9 on dense code/JSON), so a ~130K-real
	// prompt looks like ~100K est and slips past the raw context tier — then the
	// provider exact-tokenizes and 503s. The per-family multiplier
	// (calibratedContextPromptTokens) biases ONLY the context-window comparison so
	// it never over-rejects a request that fits a provider's real KV budget; the
	// dispatch-time deterministic stop is the exact backstop for what it misses.
	// Billing (estimateBillingPromptTokens) and the capacity/TTFT estimate are
	// likewise untouched.
	verdict := s.registry.PredictServable(
		model,
		estimatedPromptTokens,
		calibratedContextPromptTokens(model, estimatedPromptTokens),
		requestedMaxTokens,
		modelMaxContext,
		registry.RequestTraits{HasTools: hasTools},
		requiresVision,
		allowedProviderSerials...,
	)
	if verdict.Servable {
		return false
	}

	retryAfter := s.estimateRetryAfter(model)
	w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
	refundReservation()

	s.ddIncr("routing.decisions", []string{
		"model:" + model,
		"model_type:" + s.registry.ModelType(model),
		"outcome:unservable_429",
	})
	// Oversized-request observability (DAR-347): counts the preflight catch so it
	// can be compared against stage:dispatch (the deterministic dispatch-time stop)
	// to measure how much the estimate calibration catches before any dispatch. The
	// rejection ledger row below carries estimated_prompt_tokens / requested_max_tokens
	// for the prompt/max histograms-by-outcome.
	s.ddIncr("routing.oversized_request_rejected", []string{
		"model:" + model,
		"stage:preflight",
		"reason:" + verdict.Reason,
	})
	s.recordRejection(rejectionInfo{
		r:                     r,
		stage:                 "preflight_capacity",
		reasonCode:            verdict.Reason, // "context_exceeded" | "prompt_too_long"
		httpStatus:            http.StatusTooManyRequests,
		keyID:                 keyIDFromContext(r.Context()),
		consumerKeyHash:       store.HashKey(consumerKeyFromContext(r.Context())),
		requestedModel:        publicModel,
		resolvedModel:         model,
		stream:                stream,
		estimatedPromptTokens: estimatedPromptTokens,
		requestedMaxTokens:    requestedMaxTokens,
		requiresVision:        requiresVision,
		hasTools:              hasTools,
		retryAfterMs:          retryAfter * 1000,
		params:                rejectionSamplingParams(parsed),
		// Structurally unservable: no provider could have served it. Setting
		// servabilityComputed avoids the off-path recompute, and candidateCount 0
		// makes recordRejection mark CouldHaveServed=false.
		servabilityComputed: true,
		candidateCount:      0,
	})

	writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
		unservableMessage(publicModel, verdict, retryAfter), withCode("rate_limit_exceeded")))
	return true
}

// unservableMessage builds the client-facing 429 body for an unservable request.
func unservableMessage(publicModel string, v registry.ServabilityVerdict, retryAfterSecs int) string {
	switch v.Reason {
	case registry.ServabilityContextExceeded:
		limit := v.ContextLimit
		return fmt.Sprintf(
			"request is too large for model %q: ~%d prompt+output tokens exceeds its %d-token context window — reduce the prompt or max_tokens",
			publicModel, v.RequestTokens, limit)
	default: // ServabilityPromptTooLong
		return fmt.Sprintf(
			"request is too large for model %q on any available provider right now: ~%d prompt+output tokens exceeds the largest provider token budget — reduce the prompt or max_tokens, or retry after %ds",
			publicModel, v.RequestTokens, retryAfterSecs)
	}
}
