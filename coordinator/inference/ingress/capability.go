package ingress

import (
	"fmt"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// visionToolsFailFast is the shared media/tools capability fast-fail (mirrored
// between the two handlers). A media request must land on a constraint-eligible
// vision-capable provider, and a tool-bearing request on a provider past the
// tools version floor with a healthy chat-template render; otherwise the request
// can never route and must fail fast with a clear model_unavailable rather than
// queue for 120s into a misleading capacity 429. Both gates are constrained to
// allowedProviderSerials (a public capable provider must not satisfy an
// allowlist-pinned request) and skipped for self-route/prefer (their owned set is
// matched by ownerAccountID, not serials — those paths handle availability
// themselves and must never be wrongly blocked).
//
// rejectResponsesMedia is the chat-completions-only guard: media via the
// Responses API (`input` with no `messages`) is rejected outright because the
// Responses→chat lowering does not carry image/video parts through. Generic
// (completions/Anthropic) passes false.
//
// Returns handled=true when a terminal response was written (caller must return).
func (s *Controller) visionToolsFailFast(
	w http.ResponseWriter,
	model, publicModel string,
	requiresVision, hasTools, requiresToolConstraint bool,
	toolChoiceMode string,
	rejectResponsesMedia bool,
	policy dispatch.RoutePolicy,
	allowedProviderSerials []string,
) (handled bool) {
	if requiresVision {
		// The Responses API path lowers `input` to chat messages via
		// responsesRequestToChatCompletions, which does NOT carry image/video parts
		// through — so a media request there would be routed and then silently
		// stripped (image-blind). Reject it cleanly until that conversion preserves
		// media (tracked follow-up); the console uses /v1/chat/completions for images.
		if rejectResponsesMedia {
			httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error",
				"image/video input via the Responses API is not supported yet; use /v1/chat/completions",
				httpresponse.WithParam("input")))
			return true
		}
		// Constrain the capability check to the eligible provider set: a public
		// vision-capable provider must not satisfy a request pinned to an
		// allowlist whose members are all vision-blind. Self-route/prefer owned
		// sets are matched by ownerAccountID (not expressible as serials here),
		// so the fail-fast is skipped for them — those paths enforce their own
		// availability and we must never wrongly block them.
		if !policy.Enabled && !policy.Prefer && !s.deps.Registry().HasVisionProviderForModel(model, allowedProviderSerials...) {
			httpresponse.WriteJSON(w, http.StatusServiceUnavailable, httpresponse.ErrorBody("model_unavailable",
				fmt.Sprintf("model %q has no vision-capable provider available for image/video input right now", publicModel),
				httpresponse.WithParam("model")))
			return true
		}
	}
	// Tools fail-fast (mirrors the vision gate): when every constraint-eligible
	// provider serving this model is trait-gated — below the tools version floor,
	// below the mode-specific floor (tool_choice "none" needs the v0.7.10
	// prompt-side policy that hides declared tools), or advertising a broken
	// chat-template render — the request can never route. Without this gate it
	// passes the trait-blind QuickCapacityCheck preflight, queues for up to 120s,
	// and dies with a misleading capacity 429. The traits here must match what
	// the scheduler enforces at dispatch or the fail-fast and the queue disagree.
	// Constrained to allowedProviderSerials so a public tool-capable provider
	// can't satisfy an allowlist-pinned request. The inference-time constraint
	// gate below is owner-aware so self-route checks only owned machines while
	// prefer-owner checks both the owned pool and its public fallback.
	if hasTools && !policy.Enabled && !policy.Prefer &&
		!s.deps.Registry().HasToolCapableProviderForTraits(
			model,
			registry.RequestTraits{HasTools: true, ToolChoiceMode: toolChoiceMode},
			allowedProviderSerials...,
		) {
		httpresponse.WriteJSON(w, http.StatusServiceUnavailable, httpresponse.ErrorBody("model_unavailable",
			fmt.Sprintf("no online provider for model %q supports tool calls (requires provider >= 0.6.3 with a healthy chat template) — providers may still be updating", publicModel),
			httpresponse.WithParam("model")))
		return true
	}
	if requiresToolConstraint &&
		!s.deps.Registry().HasToolConstraintProviderForRouting(
			model,
			policy.OwnerAccountID,
			policy.Enabled,
			policy.Prefer,
			allowedProviderSerials...,
		) {
		// Distinguish "nobody can enforce this right now" (retryable, 503) from
		// "no build of this model will EVER enforce tool_choice" (permanent,
		// 400). The permanent verdict requires BOTH: the fleet serves the model
		// AND zero registered online providers even ADVERTISE the constraint
		// capability for it. The advertisement scan deliberately ignores trust
		// minimums and attestation freshness — a trust-lapsed or
		// freshness-expired enforcing provider is a transient outage, not a
		// permanent incapability, and must stay retryable — while dressing a
		// true incapability as model_unavailable would send clients into a
		// retry loop that can never succeed. Owner-scoped routing (self-route /
		// prefer) is not expressible as a serial set here, so those paths keep
		// the conservative 503.
		if !policy.Enabled && !policy.Prefer &&
			s.deps.Registry().HasProviderForModel(model, allowedProviderSerials...) &&
			!s.deps.Registry().HasProviderAdvertisingToolConstraint(model, allowedProviderSerials...) {
			httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error",
				fmt.Sprintf("inference-enforced tool_choice (required/named) is not supported for model %q", publicModel),
				httpresponse.WithParam("tool_choice")))
			return true
		}
		httpresponse.WriteJSON(w, http.StatusServiceUnavailable, httpresponse.ErrorBody("model_unavailable",
			fmt.Sprintf("no online provider for model %q advertises inference-time tool_choice enforcement", publicModel),
			httpresponse.WithParam("model")))
		return true
	}
	return false
}
