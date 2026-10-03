package inference

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"

	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// inferencePrelude carries the parsed request shape produced by the shared
// prelude: the forward body (decoded map + lazily serialized bytes), the
// untouched input bytes, and the consumer-requested model name (alias or raw
// build id, pre-resolution). originalTools is the caller's pre-normalization
// tools value when the prelude repaired a tool schema (nil otherwise); the
// tool-constraint validator must judge that view, never the repaired copy.
type inferencePrelude struct {
	body            inreq.ForwardBody
	originalRawBody []byte
	parsed          map[string]any
	model           string
	originalTools   []any
}

// parseInferencePrelude runs the request prelude shared verbatim by
// handleChatCompletions and handleGenericInference: read the body, parse JSON
// (once), normalize tool JSON-Schemas on the decoded map (so no provider sees
// chat-template-crashing shapes), require a model, and
// enforce the per-key model allowlist. On any failure it writes the exact
// OpenAI-compatible error response and returns ok=false; the caller must then
// return immediately.
func (s *Owner) parseInferencePrelude(w http.ResponseWriter, r *http.Request) (inferencePrelude, bool) {
	receivedAt := time.Now()
	// Retain the caller's body while decoding routing and request-owned fields.
	// Provider serialization is deferred until endpoint/model rewrites finish.
	// Cap it first: io.ReadAll would otherwise buffer an unbounded body and a
	// multi-GB POST would OOM the coordinator.
	r.Body = http.MaxBytesReader(w, r.Body, inreq.MaxInferenceBodyBytes)
	rawBody, err := io.ReadAll(r.Body)
	if err != nil {
		var maxBytesErr *http.MaxBytesError
		if errors.As(err, &maxBytesErr) {
			httpx.WriteJSON(w, http.StatusRequestEntityTooLarge, httpx.ErrorResponse("invalid_request_error",
				fmt.Sprintf("request body exceeds the %d-byte limit", inreq.MaxInferenceBodyBytes)))
			return inferencePrelude{}, false
		}
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "failed to read request body"))
		return inferencePrelude{}, false
	}

	parsed, ok := parseJSONBody(w, rawBody)
	if !ok {
		return inferencePrelude{}, false
	}
	// The handlers use false for an absent/non-boolean stream field. Capture
	// that parsed mode before model lookup or any subsequent validation exits.
	stream, _ := parsed["stream"].(bool)
	observation.MarkRequestStream(r, stream)

	// Normalize tool JSON-Schemas before dispatch so no provider sees the
	// schema shapes that crash Gemma-style chat templates ("upper filter
	// requires string" — nullable array types, missing types). The Swift
	// provider repairs only tools[].function.parameters, after media inlining
	// may have pushed the body past its size gate, so flat and input_schema
	// tools and large bodies depend on this pass (see toolschema.go). The
	// repair runs on the decoded map (one parse per request); the caller's
	// original tools are kept for constraint validation.
	originalTools, _ := inreq.NormalizeParsedToolSchemas(parsed, rawBody)
	if stop, ok := parsed["stop"].(string); ok {
		parsed["stop"] = []any{stop}
	}

	model, _ := parsed["model"].(string)
	if model == "" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "model is required", httpx.WithParam("model")))
		return inferencePrelude{}, false
	}

	// Per-key model allow-list enforcement (phase 3). Checked on the
	// consumer-requested name (alias or raw id) before alias resolution.
	if !s.keyModelAllowed(r.Context(), model) {
		httpx.WriteJSON(w, http.StatusForbidden, httpx.ErrorResponse("model_not_allowed",
			fmt.Sprintf("this API key is not permitted to use model %q", model), httpx.WithParam("model")))
		return inferencePrelude{}, false
	}
	// Reject an invalid caller budget before runtime defaults, alias lowering or
	// reservation accounting can replace it with an executable positive bound.
	if field := inreq.InvalidOutputTokenField(parsed); field != "" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error",
			field+" must be a non-negative integer", httpx.WithParam(field)))
		return inferencePrelude{}, false
	}

	// Own the template date before any model fallback or endpoint lowering.
	// Always overwrite the reserved field; originalRawBody remains untouched.
	promptcontract.SetRequestDate(parsed, receivedAt)

	return inferencePrelude{
		body:            inreq.ForwardBody{Parsed: parsed, Bytes: rawBody, Dirty: true},
		originalRawBody: rawBody,
		parsed:          parsed,
		model:           model,
		originalTools:   originalTools,
	}, true
}

// parseJSONBody unmarshals the request body, writing the standard invalid-JSON
// error and returning ok=false on failure. Split out so both the prelude and any
// re-parse site share one error shape.
func parseJSONBody(w http.ResponseWriter, rawBody []byte) (map[string]any, bool) {
	parsed, err := inreq.DecodeInferenceJSONObject(rawBody)
	if err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return nil, false
	}
	return parsed, true
}

// resolveRequestedBuild maps the consumer-requested model — which may be a
// public alias like "gemma-4-26b" — to the concrete build id used for routing,
// billing, and serving, returning the public name to echo back to the consumer.
// When the request used an alias it rewrites parsed["model"] to the build and
// reports rewrote=true so the caller marks its forward body dirty; it never
// serializes (the chat handler marshals once, later). Raw build ids pass
// through unchanged (publicModel == buildModel). ok=false means the alias
// currently has no usable build; the caller should surface a model_unavailable
// error. resolveRequestedModel is the body-threading variant the generic
// handler still uses.
func (s *Owner) resolveRequestedBuild(
	parsed map[string]any,
	requested string,
	allowedProviderSerials []string,
	policy selfRoutePolicy,
	traits registry.RequestTraits,
) (buildModel, publicModel string, rewrote, ok bool) {
	buildID, isAlias, resolved := s.registry.ResolveModelConstrainedWithTraits(
		requested, allowedProviderSerials, policy.ownerAccountID,
		policy.enabled, policy.prefer, traits)
	if !resolved {
		return "", requested, false, false
	}
	if !isAlias {
		return requested, requested, false, true
	}
	parsed["model"] = buildID
	return buildID, requested, true, true
}

// candidateProviderBody derives the provider-bound body the chat handler would
// send for candidateModel — the alias fallback build the admission preflight
// probes, or the resolved build itself — from the current parsed request:
// model rewritten, that build's catalog runtime defaults reconciled, the
// service reasoning policy applied, and (Responses surface) the input→chat
// lowering. It works on a shallow copy so parsed is never mutated, serializes
// once, and is memoized per request by providerBodyMemo.
func (s *Owner) candidateProviderBody(
	parsed map[string]any,
	runtimeDefaults inreq.ModelRuntimeDefaults,
	candidateModel string,
	serviceConsumer, reasoningProvided, isResponsesAPI bool,
) ([]byte, error) {
	candidateParsed := make(map[string]any, len(parsed)+1)
	for key, value := range parsed {
		candidateParsed[key] = value
	}
	candidateParsed["model"] = candidateModel
	if rec, err := s.store.GetModelRegistryRecord(candidateModel); err == nil {
		runtimeDefaults.Apply(candidateParsed, rec.RuntimeParameters)
	} else {
		runtimeDefaults.Apply(candidateParsed, nil)
	}
	inreq.ApplyResolvedModelReasoningPolicy(candidateParsed, candidateModel, serviceConsumer, reasoningProvided)
	candidateBody, err := inreq.MarshalForwardBody(candidateParsed)
	if err != nil {
		return nil, err
	}
	if isResponsesAPI {
		return promptcontract.LowerResponsesInferenceBody(candidateBody)
	}
	return candidateBody, nil
}

// visionToolsFailFast is the shared media/tools capability fast-fail (mirrored
// between the two handlers). A media request must land on a constraint-eligible
// vision-capable provider, and a tool-bearing request on a provider with a
// healthy chat-template render; otherwise the request
// can never route and must fail fast with a clear model_unavailable rather than
// queue for 120s into a misleading capacity 429. Both gates are constrained to
// allowedProviderSerials (a public capable provider must not satisfy an
// allowlist-pinned request) and skipped for self-route/prefer (their owned set is
// matched by ownerAccountID, not serials — those paths handle availability
// themselves and must never be wrongly blocked).
//
// Returns handled=true when a terminal response was written (caller must return).
func (s *Owner) visionToolsFailFast(
	w http.ResponseWriter,
	model, publicModel string,
	requiresVision, hasTools, requiresToolConstraint bool,
	toolChoiceMode string,
	policy selfRoutePolicy,
	allowedProviderSerials []string,
) (handled bool) {
	if requiresVision {
		// Constrain the capability check to the eligible provider set: a public
		// vision-capable provider must not satisfy a request pinned to an
		// allowlist whose members are all vision-blind. Self-route/prefer owned
		// sets are matched by ownerAccountID (not expressible as serials here),
		// so the fail-fast is skipped for them — those paths enforce their own
		// availability and we must never wrongly block them.
		if !policy.enabled && !policy.prefer && !s.registry.HasVisionProviderForModel(model, allowedProviderSerials...) {
			httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("model_unavailable",
				fmt.Sprintf("model %q has no vision-capable provider available for image/video input right now", publicModel), httpx.WithParam("model")))
			return true
		}
	}
	// Tools fail-fast (mirrors the vision gate): when every constraint-eligible
	// provider serving this model is trait-gated — chiefly by advertising a
	// broken chat-template render (template_render_ok=false) — the request can
	// never route. Without this gate it
	// passes the trait-blind QuickCapacityCheck preflight, queues for up to 120s,
	// and dies with a misleading capacity 429. The traits here must match what
	// the scheduler enforces at dispatch or the fail-fast and the queue disagree.
	// Constrained to allowedProviderSerials so a public tool-capable provider
	// can't satisfy an allowlist-pinned request. The inference-time constraint
	// gate below is owner-aware so self-route checks only owned machines while
	// prefer-owner checks both the owned pool and its public fallback.
	if hasTools && !policy.enabled && !policy.prefer &&
		!s.registry.HasToolCapableProviderForTraits(
			model,
			registry.RequestTraits{HasTools: true, ToolChoiceMode: toolChoiceMode},
			allowedProviderSerials...,
		) {
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("model_unavailable",
			fmt.Sprintf("no online provider for model %q supports tool calls with a healthy chat template right now", publicModel), httpx.WithParam("model")))
		return true
	}
	if requiresToolConstraint &&
		!s.registry.HasToolConstraintProviderForRouting(
			model,
			policy.ownerAccountID,
			policy.enabled,
			policy.prefer,
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
		if !policy.enabled && !policy.prefer &&
			s.registry.HasProviderForModel(model, allowedProviderSerials...) &&
			!s.registry.HasProviderAdvertisingToolConstraint(model, allowedProviderSerials...) {
			httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error",
				fmt.Sprintf("inference-enforced tool_choice (required/named) is not supported for model %q", publicModel), httpx.WithParam("tool_choice")))
			return true
		}
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("model_unavailable",
			fmt.Sprintf("no online provider for model %q advertises inference-time tool_choice enforcement", publicModel), httpx.WithParam("model")))
		return true
	}
	return false
}
