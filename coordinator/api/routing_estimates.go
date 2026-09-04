package api

// Routing-side output estimate (consumer request path glue).
//
// Two numbers describe a request's output for the coordinator, and they are
// deliberately NOT the same:
//
//   - requestedMaxTokens — the FORWARDED bound. When the client omits max_tokens
//     ensureMaxTokensBound injects the model's max_output_length into the body
//     before estimateRequestedMaxTokens reads it, so this is what the provider
//     may actually generate and what its own ledger reserves (prompt + max).
//     It stays the input to everything that must mirror the provider or bound
//     money: coordinator admission (freeMemoryAdmits, pendingTokenBudget,
//     providerBudgetFits), the servability gate (PredictServable), the capacity
//     probes, the balance hold (issue #33), finish_reason truncation and the
//     ITPM/OTPM charge. Relaxing any of those below the forwarded bound
//     produces admit → token_budget_exhausted 503s that arm budget_clamp /
//     capacity cooldowns against healthy pairs.
//
//   - expectedCompletionTokens — the ROUTING decode length the scheduler ranks
//     with (PendingRequest.ExpectedCompletionTokens → thisReqDecodeTokens). Only
//     the cost function reads it. It is the learned per-model estimate
//     (registry/completion_calibration.go: clamp(p90 × 1.25, 64, bound)) once
//     warm; before warm-up it is the client's explicit value when present and
//     the pre-injection 256 × n default when absent — so a request without
//     max_tokens no longer scores as if it will produce the whole 8–32K window.
//     Note that the cold+absent case is itself a ranking change versus the
//     injected bound (256 matches AssumedCompletionTokens); the kill switch
//     (EIGENINFERENCE_COMPLETION_CALIBRATION=off) restores the bound for
//     explicit and omitted max_tokens alike — it is checked BEFORE the cold
//     rules below, so an operator flipping it during an incident gets the
//     pre-calibration ranking for the dominant omitted-max_tokens traffic
//     without a deploy.

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// expectedCompletionTokensForRouting resolves the routing-only decode length
// for a request whose forwarded max-tokens bound is forwardedMaxTokens (see the
// file comment). parsed is the request body AFTER ensureMaxTokensBound, so the
// explicit/absent distinction comes from clientSetMaxTokens, captured by the
// caller before the injection.
func (s *Server) expectedCompletionTokensForRouting(model string, parsed map[string]any, clientSetMaxTokens bool, forwardedMaxTokens int) int {
	if s != nil && s.registry != nil {
		if !s.registry.CompletionCalibrationEnabled() {
			// Kill switch: the pre-calibration cost byte-for-byte, i.e. the
			// forwarded bound — never the 256 × n cold default.
			return forwardedMaxTokens
		}
		if expected, learned := s.registry.ExpectedCompletionTokensLearned(model, forwardedMaxTokens); learned {
			return expected
		}
	}
	if clientSetMaxTokens {
		// Explicit bound: forwardedMaxTokens already equals the client's value
		// (× n), so this is today's behaviour byte-for-byte before warm-up.
		return forwardedMaxTokens
	}
	return defaultRoutingMaxTokens(parsed)
}

// observeCompletionLength feeds the completion-length calibrator
// (registry/completion_calibration.go) one completion's
// usage.completion_tokens. Reached only through settleCompletion /
// settleDeferredCompletion, i.e. from the SERVED attempt's terminal; the pr
// fields read here are immutable after dispatch.
//
// Skipped when the consumer had already disconnected (consumerGone): a
// truncated sample would pull p90 down, the router would plan for shorter
// decodes and pack boxes harder, and more streams would be abandoned — the
// wrong feedback direction under exactly the load where it matters. Also
// skipped when the completion is right-censored by the forwarded bound
// (completionTokens >= RequestedMaxTokens): that observation is the bound,
// not the completion length. A speculative-race loser's terminal is a
// cancelled, truncated generation and never reaches here (settleCompletion
// parks it and no commit follows); the winner's count is not biased by the
// race the way TTFT is and is kept.
func (s *Server) observeCompletionLength(pr *registry.PendingRequest, completionTokens int, consumerGone bool) {
	if s == nil || s.registry == nil || pr == nil || consumerGone {
		return
	}
	if pr.RequestedMaxTokens > 0 && completionTokens >= pr.RequestedMaxTokens {
		return
	}
	s.registry.RecordCompletionObservation(pr.Model, completionTokens)
}
