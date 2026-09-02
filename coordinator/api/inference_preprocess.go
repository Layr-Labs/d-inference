package api

// Shared request preprocessing for the consumer inference handlers.
//
// handleChatCompletions and handleGenericInference (completions + Anthropic
// messages) historically carried byte-identical copies of the request prelude
// (body read → tool-schema normalize → JSON parse → model-required → per-key
// model allowlist) and the vision/tools fail-fast gates. This file factors those
// shared sequences into single helpers so the two handlers can't drift. The
// helpers preserve EXACT behavior — identical error types, messages, params, and
// status codes — and write the terminal response themselves, signalling the
// caller to return via ok=false / handled=true.
//
// The prelude parses the body exactly once. Every later rewrite (stop
// normalization, alias resolution, reasoning policy, runtime defaults,
// max_tokens bound, …) mutates the decoded map and marks the forwardBody
// dirty; the bytes are serialized once, lazily, when the first consumer of
// the provider-bound body asks for them.

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// maxInferenceBodyBytes caps the plaintext inference request body. Without it
// the common (non-sealed) path does io.ReadAll(r.Body) with no limit, so any
// API-key holder could POST a multi-GB body and OOM the coordinator (the trusted
// TEE component).
//
// Sized to the PROVIDER WebSocket frame budget, not just OOM-safety: the
// coordinator encrypts rawBody and sends the base64 NaCl-box as ONE WS frame
// (consumer.go), and the Swift provider rejects frames over 32 MiB by tearing
// down the whole session + cancelling every unrelated in-flight request
// (CoordinatorClient.maxInboundMessageBytes). base64 adds ×4/3, so a 16 MiB body
// → ~21.3 MiB frame, comfortably under 32 MiB — the budget that provider cap was
// sized against, and identical to the sealed path (sender_encryption.go). A
// larger cap would let a request pass here only to disconnect the provider
// instead of returning a clean 413.
//
// The console already trims image history to the newest image turn
// (chat-messages.ts), but a single 4×10 MB turn (~53 MiB) still exceeds this and
// is undeliverable to any provider — aligning the per-turn UI image budget with
// the frame cap is tracked separately.
//
// This caps the body we READ. The body we actually SEAL can differ: the handlers
// re-marshal the parsed request after mutating it (max_tokens injection, tool
// normalization). The cap is therefore re-checked on that final body before
// encryption (see handleChatCompletions / handleGenericInference) using
// marshalForwardBody, which also disables HTML escaping so the re-marshal can't
// silently inflate a benign body past this limit.
const maxInferenceBodyBytes = 16 << 20 // 16 MiB

// marshalForwardBody serializes a parsed request body for forwarding to a
// provider WITHOUT HTML escaping. encoding/json's default Marshal escapes the
// bytes '<', '>', and '&' into their 6-byte \uXXXX forms — a 6× per-character
// inflation that is meaningless on this path (the body is sealed and parsed as
// JSON by the provider, never embedded in HTML) yet can balloon a benign request
// — e.g. a prompt containing a long run of '<' — past the provider's
// single-frame WebSocket limit, tearing down its session. Disabling escaping
// keeps the re-marshaled body within a small constant of the (already
// size-capped) input. Mirrors NormalizeToolSchemas's own non-escaping round-trip.
func marshalForwardBody(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	// Encoder.Encode appends a trailing newline the encrypted body shouldn't carry.
	return bytes.TrimSuffix(buf.Bytes(), []byte{'\n'}), nil
}

// forwardBody is the provider-bound request as the handler reshapes it: the
// decoded map every rewrite is applied to, plus the bytes that map was last
// serialized to. bytes starts as the caller's verbatim input, so a request
// that needs no rewrite at all reaches the provider byte-for-byte as sent;
// after any mutation the handler marks the body dirty and current() serializes
// once, however many rewrites preceded it.
type forwardBody struct {
	parsed map[string]any
	bytes  []byte
	dirty  bool
}

// markDirty records that parsed has diverged from bytes.
func (b *forwardBody) markDirty() { b.dirty = true }

// current returns bytes reflecting every mutation so far, serializing only when
// something changed since the last serialization (or since the input was read).
func (b *forwardBody) current() ([]byte, error) {
	if !b.dirty {
		return b.bytes, nil
	}
	out, err := marshalForwardBody(b.parsed)
	if err != nil {
		return nil, err
	}
	b.bytes, b.dirty = out, false
	return out, nil
}

// replace adopts bytes a helper already serialized from parsed (remote media
// inlining re-marshals after mutating parsed in place).
func (b *forwardBody) replace(serialized []byte) {
	b.bytes, b.dirty = serialized, false
}

// inferencePrelude carries the parsed request shape produced by the shared
// prelude: the forward body (decoded map + lazily serialized bytes), the
// untouched input bytes, and the consumer-requested model name (alias or raw
// build id, pre-resolution). originalTools is the caller's pre-normalization
// tools value when the prelude repaired a tool schema (nil otherwise); the
// tool-constraint validator must judge that view, never the repaired copy.
type inferencePrelude struct {
	body            forwardBody
	originalRawBody []byte
	parsed          map[string]any
	model           string
	originalTools   []any
}

// parseInferencePrelude runs the request prelude shared verbatim by
// handleChatCompletions and handleGenericInference: read the body, parse JSON
// (once), normalize tool JSON-Schemas on the decoded map (so pre-0.6.3
// providers never see chat-template-crashing shapes), require a model, and
// enforce the per-key model allowlist. On any failure it writes the exact
// OpenAI-compatible error response and returns ok=false; the caller must then
// return immediately.
func (s *Server) parseInferencePrelude(w http.ResponseWriter, r *http.Request) (inferencePrelude, bool) {
	// Read the raw request body so we can forward it as-is to the provider.
	// We only parse minimally to extract model/stream/messages for routing.
	// Cap it first: io.ReadAll would otherwise buffer an unbounded body and a
	// multi-GB POST would OOM the coordinator.
	r.Body = http.MaxBytesReader(w, r.Body, maxInferenceBodyBytes)
	rawBody, err := io.ReadAll(r.Body)
	if err != nil {
		var maxBytesErr *http.MaxBytesError
		if errors.As(err, &maxBytesErr) {
			writeJSON(w, http.StatusRequestEntityTooLarge, errorResponse("invalid_request_error",
				fmt.Sprintf("request body exceeds the %d-byte limit", maxInferenceBodyBytes)))
			return inferencePrelude{}, false
		}
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "failed to read request body"))
		return inferencePrelude{}, false
	}

	parsed, ok := parseJSONBody(w, rawBody)
	if !ok {
		return inferencePrelude{}, false
	}

	// Normalize tool JSON-Schemas before dispatch so providers running binaries
	// older than 0.6.3 (which normalize provider-side, #310) never see the
	// schema shapes that crash Gemma-style chat templates ("upper filter
	// requires string" — nullable array types, missing types). Centralizing
	// this in the coordinator covers the whole fleet the moment the
	// coordinator deploys, instead of waiting out provider update lag. The
	// repair runs on the decoded map (one parse per request); the caller's
	// original tools are kept for constraint validation.
	originalTools, dirty := normalizeParsedToolSchemas(parsed, len(rawBody))
	if stop, ok := parsed["stop"].(string); ok {
		parsed["stop"] = []any{stop}
		dirty = true
	}

	model, _ := parsed["model"].(string)
	if model == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "model is required", withParam("model")))
		return inferencePrelude{}, false
	}

	// Per-key model allow-list enforcement (phase 3). Checked on the
	// consumer-requested name (alias or raw id) before alias resolution.
	if !s.keyModelAllowed(r.Context(), model) {
		writeJSON(w, http.StatusForbidden, errorResponse("model_not_allowed",
			fmt.Sprintf("this API key is not permitted to use model %q", model), withParam("model")))
		return inferencePrelude{}, false
	}

	return inferencePrelude{
		body:            forwardBody{parsed: parsed, bytes: rawBody, dirty: dirty},
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
	parsed, err := decodeInferenceJSONObject(rawBody)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return nil, false
	}
	return parsed, true
}

// decodeInferenceJSONObject preserves every JSON number as json.Number. The
// handlers re-marshal requests when they resolve aliases, lower endpoints,
// normalize stop sequences, or strip legacy-only fields. Decoding through
// float64 first would silently change precision-sensitive tool-schema values
// before the provider compiles them (for example, 2^53+1 becomes 2^53).
func decodeInferenceJSONObject(rawBody []byte) (map[string]any, error) {
	decoder := json.NewDecoder(bytes.NewReader(rawBody))
	decoder.UseNumber()
	var parsed map[string]any
	if err := decoder.Decode(&parsed); err != nil {
		return nil, err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return nil, errors.New("multiple JSON values")
		}
		return nil, err
	}
	return parsed, nil
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
func (s *Server) resolveRequestedBuild(
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
func (s *Server) candidateProviderBody(
	parsed map[string]any,
	runtimeDefaults modelRuntimeDefaults,
	candidateModel string,
	serviceConsumer, reasoningProvided, isResponsesAPI bool,
) ([]byte, error) {
	candidateParsed := make(map[string]any, len(parsed)+1)
	for key, value := range parsed {
		candidateParsed[key] = value
	}
	candidateParsed["model"] = candidateModel
	if rec, err := s.store.GetModelRegistryRecord(candidateModel); err == nil {
		runtimeDefaults.apply(candidateParsed, rec.RuntimeParameters)
	} else {
		runtimeDefaults.apply(candidateParsed, nil)
	}
	applyResolvedModelReasoningPolicy(candidateParsed, candidateModel, serviceConsumer, reasoningProvided)
	candidateBody, err := marshalForwardBody(candidateParsed)
	if err != nil {
		return nil, err
	}
	if isResponsesAPI {
		return promptcontract.LowerProviderBody(promptcontract.EndpointResponses, candidateBody)
	}
	return candidateBody, nil
}

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
func (s *Server) visionToolsFailFast(
	w http.ResponseWriter,
	model, publicModel string,
	requiresVision, hasTools, requiresToolConstraint bool,
	toolChoiceMode string,
	rejectResponsesMedia bool,
	policy selfRoutePolicy,
	allowedProviderSerials []string,
) (handled bool) {
	if requiresVision {
		// The Responses API path lowers `input` to chat messages via
		// responsesRequestToChatCompletions, which does NOT carry image/video parts
		// through — so a media request there would be routed and then silently
		// stripped (image-blind). Reject it cleanly until that conversion preserves
		// media (tracked follow-up); the console uses /v1/chat/completions for images.
		if rejectResponsesMedia {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
				"image/video input via the Responses API is not supported yet; use /v1/chat/completions",
				withParam("input")))
			return true
		}
		// Constrain the capability check to the eligible provider set: a public
		// vision-capable provider must not satisfy a request pinned to an
		// allowlist whose members are all vision-blind. Self-route/prefer owned
		// sets are matched by ownerAccountID (not expressible as serials here),
		// so the fail-fast is skipped for them — those paths enforce their own
		// availability and we must never wrongly block them.
		if !policy.enabled && !policy.prefer && !s.registry.HasVisionProviderForModel(model, allowedProviderSerials...) {
			writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_unavailable",
				fmt.Sprintf("model %q has no vision-capable provider available for image/video input right now", publicModel),
				withParam("model")))
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
	if hasTools && !policy.enabled && !policy.prefer &&
		!s.registry.HasToolCapableProviderForTraits(
			model,
			registry.RequestTraits{HasTools: true, ToolChoiceMode: toolChoiceMode},
			allowedProviderSerials...,
		) {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_unavailable",
			fmt.Sprintf("no online provider for model %q supports tool calls (requires provider >= 0.6.3 with a healthy chat template) — providers may still be updating", publicModel),
			withParam("model")))
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
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
				fmt.Sprintf("inference-enforced tool_choice (required/named) is not supported for model %q", publicModel),
				withParam("tool_choice")))
			return true
		}
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_unavailable",
			fmt.Sprintf("no online provider for model %q advertises inference-time tool_choice enforcement", publicModel),
			withParam("model")))
		return true
	}
	return false
}
