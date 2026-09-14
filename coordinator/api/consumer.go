package api

// Consumer-facing API handlers for the Darkbloom coordinator.
//
// This file implements the OpenAI-compatible HTTP endpoints that consumers
// use to send inference requests. The coordinator acts as a trusted routing
// layer between consumers and providers.
//
// Trust model:
//   The coordinator runs in a Confidential VM, providing hardware-encrypted
//   memory. Consumers may additionally sender-seal requests to the
//   coordinator's X25519 key. The coordinator decrypts for routing purposes
//   but never logs prompt content, then re-encrypts each request to the
//   selected provider's X25519 public key before forwarding over the
//   WebSocket. Providers are attested via Secure Enclave challenge-response.

import (
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/inference/response"
	"github.com/eigeninference/d-inference/coordinator/inference/toolpolicy"
	"github.com/eigeninference/d-inference/coordinator/modelpolicy"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// FirstContentDeadline returns this server's request-absolute first-content
// budget for a concrete model. The ordinary base is instance-owned so
// production-like E2E servers can use the production value without mutating
// concurrent unit tests. Exact-model overrides and the fixed 1ms/token slope
// are centralized in modelpolicy.
func (s *Server) FirstContentDeadline(model string, estimatedPromptTokens int) time.Duration {
	base := s.firstContentDeadlineBase
	if base <= 0 {
		base = dispatch.DefaultFirstContentDeadlineBase
	}
	return modelpolicy.CoordinatorFirstContentDeadline(model, estimatedPromptTokens, base)
}

// shedIfModelRejected answers a public/prefer-owner request with 429 +
// Retry-After when its requested alias or resolved build is in the operator
// reject set (EIGENINFERENCE_REJECT_MODELS). This is a deterministic
// per-model circuit breaker: it takes an unhealthy model out of rotation before
// rate-limit, reservation, or routing work, so aggregators see rate limiting
// rather than dropped/cancelled streams. Exclusive self-route bypasses the shed
// because it never falls back to the public fleet.
func (s *Server) shedIfModelRejected(w http.ResponseWriter, r *http.Request, parsed map[string]any, policy selfRoutePolicy, publicModel, model string, stream bool, estimatedPromptTokens, requestedMaxTokens int, requiresVision, hasTools bool) bool {
	if policy.Enabled || !s.modelShed(model, publicModel) {
		return false
	}
	retryAfter := s.inferenceDispatch().EstimateRetryAfter(model)
	if retryAfter <= 0 {
		retryAfter = 30
	}
	s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:model_shed"})
	s.recordRejection(rejectionInfo{
		Request:               r,
		Stage:                 "model_shed",
		ReasonCode:            "model_shed",
		HttpStatus:            http.StatusTooManyRequests,
		KeyID:                 requestcontext.KeyID(r.Context()),
		ConsumerKeyHash:       store.HashKey(consumerKeyFromContext(r.Context())),
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
	writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
		fmt.Sprintf("model %q is temporarily rate-limited — retry after %ds", publicModel, retryAfter),
		withCode("rate_limit_exceeded")))
	return true
}

// writeGenericProviderError writes the terminal HTTP body for a provider error
// on paths WITHOUT a failover ladder or in-band SSE error framing: the generic
// inference handlers (/v1/messages, /v1/completions) and the non-streaming
// chat response assembly. Deterministic non-provider-fault reasons surface the
// SAME curated bodies as the chat dispatch ladder — a jinja_* template-render
// failure becomes the 422 model_capability invalid_request_error (the raw
// template backtrace never reaches a client), gated by the ladder's
// EIGENINFERENCE_JINJA_TERMINAL_REJECT kill switch; tool_noncompliance keeps
// its provider-typed 422 message (already curated and content-free) but in the
// invalid_request_error/model_capability envelope instead of provider_error.
// Every other error is mapped from the closed failure_code vocabulary. Raw
// provider prose is never passed through.
func (s *Server) writeGenericProviderError(w http.ResponseWriter, errMsg protocol.InferenceErrorMessage) {
	errMsg = attempt.NormalizeInferenceErrorForInternalUse(errMsg)
	if dispatch.JinjaTerminalRejectEnabled() && attempt.IsJinjaTemplateErrorReason(errMsg.ErrorReason) {
		writeJSON(w, http.StatusUnprocessableEntity,
			errorResponse("invalid_request_error", dispatch.JinjaTerminalRejectMessage, withCode("model_capability")))
		return
	}
	if attempt.NormalizeInferenceErrorReason(errMsg.ErrorReason) == attempt.ErrorReasonToolNoncompliance {
		writeJSON(w, http.StatusUnprocessableEntity,
			errorResponse("invalid_request_error", response.ClientSafeInferenceErrorMessage(errMsg), withCode("model_capability")))
		return
	}
	statusCode := errMsg.StatusCode
	if statusCode == 0 {
		statusCode = http.StatusBadGateway
	}
	writeJSON(w, statusCode, errorResponse("provider_error", response.ClientSafeInferenceErrorMessage(errMsg)))
}

// resolveRequestedModel maps the consumer-requested model — which may be a
// public alias like "gemma-4-26b" — to the concrete build id used for routing,
// billing, and serving, returning the public name to echo back to the consumer.
// When the request used an alias it rewrites parsed["model"] and returns an
// updated rawBody so the provider receives the concrete build. Raw build ids
// pass through unchanged (publicModel == buildModel). ok=false means the alias
// currently has no usable build; the caller should surface a model_unavailable
// error.
func (s *Server) resolveRequestedModel(
	parsed map[string]any,
	rawBody []byte,
	requested string,
	allowedProviderSerials []string,
	policy selfRoutePolicy,
	traits registry.RequestTraits,
) (buildModel, publicModel string, newRawBody []byte, ok bool) {
	buildID, isAlias, resolved := s.registry.ResolveModelConstrainedWithTraits(
		requested, allowedProviderSerials, policy.OwnerAccountID,
		policy.Enabled, policy.Prefer, traits)
	if !resolved {
		return "", requested, rawBody, false
	}
	if !isAlias {
		return requested, requested, rawBody, true
	}
	parsed["model"] = buildID
	rb, err := marshalForwardBody(parsed)
	if err != nil {
		rb = rawBody
	}
	return buildID, requested, rb, true
}

// aliasFallbackMode selects the failure policy for maybeFallbackAlias.
type aliasFallbackMode int

const (
	// aliasFallbackCapacity routes to Previous whenever it has any free capacity.
	aliasFallbackCapacity aliasFallbackMode = iota
	// aliasFallbackTTFT additionally rejects Previous when its best TTFT estimate
	// would miss the per-request ceiling (ttftThreshold).
	aliasFallbackTTFT
)

// maybeFallbackAlias keeps public aliases available during a desired-build
// saturation event. Alias resolution intentionally prefers Desired when it is
// routable, but if every desired provider is transiently full (aliasFallbackCapacity)
// or too slow to hit the TTFT ceiling (aliasFallbackTTFT) and Previous can serve,
// route this request to Previous instead of returning a fast 429 / slow stream.
// Hard constraints and permanent model-too-large failures are handled by the
// caller and do not use this fallback. The TTFT estimate for Previous is also
// returned so the caller does not need to recompute it. ttftThreshold is the
// request-local deadline pinned before admission and is only consulted in
// aliasFallbackTTFT mode.
func (s *Server) maybeFallbackAlias(parsed map[string]any, mode aliasFallbackMode, publicModel, currentModel string, estimatedPromptTokens, requestedMaxTokens int, ttftThreshold time.Duration, traits registry.RequestTraits, requiresVision bool, allowedProviderSerials []string) (string, int, int, int, time.Duration, bool, bool) {
	if publicModel == "" || publicModel == currentModel {
		return currentModel, 0, 0, 0, 0, false, false
	}
	target, ok := s.registry.AliasTarget(publicModel)
	if !ok || target.Desired != currentModel || target.Previous == "" {
		return currentModel, 0, 0, 0, 0, false, false
	}
	// Previous must be a real, non-shed catalog build before we probe it.
	if s.modelShed(target.Previous, publicModel) || !s.registry.IsModelInCatalog(target.Previous) {
		return currentModel, 0, 0, 0, 0, false, false
	}
	// A SINGLE Previous-build probe drives both modes; the mode only decides
	// whether the probe's TTFT estimate also gates the fallback.
	candidates, rejections, tooLarge, bestTTFT, hasTTFT := s.registry.QuickCapacityCheckWithTTFTForRequest(target.Previous, estimatedPromptTokens, requestedMaxTokens, traits, requiresVision, allowedProviderSerials...)
	enforceTTFT := mode == aliasFallbackTTFT
	if candidates <= 0 || (enforceTTFT && ttftTooSlow(bestTTFT, hasTTFT, ttftThreshold)) {
		// No fallback. TTFT mode reports the probed Previous build (the caller
		// uses it as the alternate TTFT estimate); capacity mode discards the
		// model, so keep the unchanged current build.
		failModel := currentModel
		if enforceTTFT {
			failModel = target.Previous
		}
		return failModel, candidates, rejections, tooLarge, bestTTFT, hasTTFT, false
	}
	parsed["model"] = target.Previous
	return target.Previous, candidates, rejections, tooLarge, bestTTFT, hasTTFT, true
}

func ttftTooSlow(bestTTFT time.Duration, hasTTFT bool, threshold time.Duration) bool {
	return hasTTFT && bestTTFT > threshold
}

func fasterTTFTEstimate(primaryModel string, primary time.Duration, alternateModel string, alternate time.Duration, alternateOK bool) (string, time.Duration) {
	if alternateOK && alternate < primary {
		return alternateModel, alternate
	}
	return primaryModel, primary
}

// ttftMsForRejection converts a pre-flight TTFT estimate to milliseconds for the
// rejection ledger, returning 0 when the pre-flight produced no estimate.
func ttftMsForRejection(bestTTFT time.Duration, hasTTFT bool) float64 {
	if !hasTTFT {
		return 0
	}
	return float64(bestTTFT.Milliseconds())
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

// defaultMaxOutputTokens is the ceiling injected into requests that don't set
// max_tokens. It bounds the worst-case cost of a single inference so the
// pre-flight balance reservation covers the entire generation; without this
// cap a consumer could stream output exceeding their reservation and the
// post-inference charge would fail silently (see GitHub issue #33). Consumers
// who need longer generations must set max_tokens explicitly and carry the
// balance to cover it.
const defaultMaxOutputTokens = 8192

// explicitMaxTokens returns the consumer-specified max output tokens from any
// of the recognized field names, or 0 if none were set.
func explicitMaxTokens(parsed map[string]any) int {
	for _, key := range []string{"max_tokens", "max_completion_tokens", "max_output_tokens"} {
		if n, ok := intFromRequestValue(parsed[key]); ok && n > 0 {
			return n
		}
	}
	return 0
}

// writeServiceUnavailable writes a retryable 503 with a Retry-After header so
// clients (and OpenRouter) can schedule the retry instead of blind backoff.
func (s *Server) writeServiceUnavailable(w http.ResponseWriter, model string) {
	w.Header().Set("Retry-After", strconv.Itoa(s.inferenceDispatch().EstimateRetryAfter(model)))
	writeJSON(w, http.StatusServiceUnavailable, errorResponse("service_unavailable",
		"service temporarily unavailable — please retry"))
}

// ensureMaxTokensBound injects a max-tokens bound into parsed when the
// consumer didn't specify any max-tokens field, so the outgoing request to
// the provider is bounded by the amount we reserve upfront. The bound is
// the model's max_output_length from the registry (or defaultMaxOutputTokens
// as fallback). The injected field name depends on the API flavor: Responses
// API uses max_output_tokens, everything else uses max_tokens. Returns true
// when an injection occurred, so the caller can re-marshal the outgoing body
// if needed.
func ensureMaxTokensBound(parsed map[string]any, isResponsesAPI bool, bound int) bool {
	if n := explicitMaxTokens(parsed); n > 0 {
		// Normalize alias fields the provider engine doesn't read: a chat
		// request bounded only via max_completion_tokens (the OpenAI-preferred
		// spelling) must still reach the provider as max_tokens, or the bound
		// is silently ignored.
		if !isResponsesAPI {
			if cur, ok := intFromRequestValue(parsed["max_tokens"]); !ok || cur <= 0 {
				parsed["max_tokens"] = n
				return true
			}
		}
		return false
	}
	if isResponsesAPI {
		parsed["max_output_tokens"] = bound
	} else {
		parsed["max_tokens"] = bound
	}
	return true
}

// handleChatCompletions handles POST /v1/chat/completions.
//
// This is the main inference endpoint. It validates the request, finds an
// available provider for the requested model, forwards the request via
// WebSocket, and either streams SSE chunks or assembles a complete response.
//
// Chat-completions bodies are passed through to the provider, preserving all
// OpenAI-compatible fields. Responses API bodies are lowered into that same
// provider-facing chat shape while their original parsed form remains the
// source for accounting and consumer-facing response conversion.
func (s *Server) handleChatCompletions(w http.ResponseWriter, r *http.Request) {
	timing := &registry.RequestTiming{ReceivedAt: time.Now()}
	rp := s.newRequestProfile(r, "", "", false)

	// Shared prelude: read body, normalize tool schemas, parse, require a model,
	// enforce the per-key model allowlist. (See parseInferencePrelude.)
	prelude, ok := s.parseInferencePrelude(w, r)
	if !ok {
		return
	}
	// body is the provider-bound request: every rewrite below mutates
	// body.parsed (== parsed) and marks it dirty; the bytes are serialized ONCE,
	// at the single serialization point ahead of the first consumer of the
	// provider body. originalRawBody stays the caller's untouched input.
	body := &prelude.body
	originalRawBody := prelude.originalRawBody
	parsed := prelude.parsed
	model := prelude.model
	runtimeDefaults := newModelRuntimeDefaults(parsed)
	_, reasoningProvided := parsed["reasoning"]

	// Accept either chat completions format (messages) or Responses API format
	// (input). Responses requests are lowered before the provider body is sealed.
	messages, _ := parsed["messages"].([]any)
	input := parsed["input"]
	if len(messages) == 0 && input == nil {
		s.recordRejection(rejectionInfo{
			Request:         r,
			Stage:           "validation",
			ReasonCode:      "messages_required",
			HttpStatus:      http.StatusBadRequest,
			KeyID:           requestcontext.KeyID(r.Context()),
			ConsumerKeyHash: store.HashKey(consumerKeyFromContext(r.Context())),
			RequestedModel:  model,
			Params:          rejectionSamplingParams(parsed),
		})
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "messages or input is required"))
		return
	}

	// Multiple choices per request are not supported — fail loudly instead of
	// silently returning a single choice the consumer didn't ask for.
	if copies, ok := intFromRequestValue(parsed["n"]); ok && copies > 1 {
		s.recordRejection(rejectionInfo{
			Request:         r,
			Stage:           "validation",
			ReasonCode:      "bad_param",
			HttpStatus:      http.StatusBadRequest,
			KeyID:           requestcontext.KeyID(r.Context()),
			ConsumerKeyHash: store.HashKey(consumerKeyFromContext(r.Context())),
			RequestedModel:  model,
			N:               copies,
			Params:          rejectionSamplingParams(parsed),
		})
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			"n > 1 is not supported", withParam("n")))
		return
	}

	var allowedProviderSerials []string
	if stripProviderRoutingFields(parsed) {
		body.markDirty()
	}
	if response.ApplyMetadataDetailsRequest(r, parsed) {
		body.markDirty()
	}

	// "Use my own machine, for free" opt-in. The signal is the
	// X-Darkbloom-Route header (OpenAI-client-safe: invisible to the body
	// schema) OR a per-key hard ceiling. The header can only *request*
	// self-routing; it cannot name a machine — ownership is matched on the
	// coordinator-stamped provider AccountID, so nothing here is forgeable.
	policy := s.resolveSelfRoutePolicy(r)

	isResponsesAPI := input != nil && len(messages) == 0
	// Tool-constraint validation must judge the PRE-normalization tools (a
	// normalization marker in the caller's body is forged). On the chat surface
	// that is the parsed map with the caller's original tools restored; the
	// Responses surface needs the input→chat lowering, which works on bytes, so
	// the untouched input is lowered and parsed once.
	var validatedPolicy toolpolicy.Policy
	var validationErr error
	if isResponsesAPI {
		loweredConstraintBody, err := promptcontract.LowerProviderBody(
			promptcontract.EndpointResponses, originalRawBody)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, errorResponse(
				"invalid_request_error", err.Error()))
			return
		}
		validatedPolicy, validationErr = toolpolicy.ValidateBytes(loweredConstraintBody)
	} else {
		validatedPolicy, validationErr = toolpolicy.ValidateParsed(parsed, prelude.originalTools)
	}
	if validationErr != nil {
		s.recordToolConstraintMetric(validatedPolicy.Mode, "compile_rejection")
		writeToolConstraintValidationError(w, validationErr)
		return
	}
	// Derive request-shape traits before alias resolution. During a
	// mixed-version rollout Desired may have ordinary providers while Previous
	// has the only provider capable of enforcing this exact tool policy. One
	// walk of the message tree yields the media count, the tools flag, and the
	// routing/billing token estimates (consumed below, after the rewrites). It
	// runs after constraint validation so a rejected tool policy on a large
	// body never pays the walk.
	shape := introspectRequest(parsed)
	requiresVision := shape.requiresVision()
	hasTools := shape.hasTools
	validatedMode := validatedPolicy.Mode
	toolChoiceName := validatedPolicy.Name
	parallelToolCalls := validatedPolicy.Parallel
	s.recordToolConstraintMetric(validatedMode, "requested")
	requiresToolConstraint := validatedMode.RequiresInferenceConstraint()
	if requiresToolConstraint && requiresVision {
		writeJSON(w, http.StatusBadRequest, errorResponse(
			"invalid_request_error",
			"inference-enforced tool_choice is not supported for multimodal requests",
			withParam("tool_choice")))
		return
	}
	aliasTraits := registry.RequestTraits{
		HasTools:               hasTools,
		RequiresToolConstraint: requiresToolConstraint,
		ToolChoiceMode:         string(validatedMode),
		ToolChoiceName:         toolChoiceName,
		ParallelToolCalls:      parallelToolCalls,
	}

	// Resolve a public alias (e.g. "gemma-4-26b") to a concrete build id, now
	// that coordinator routing constraints and self-route policy are known so
	// the pick only considers builds the constrained provider set can actually
	// serve. From here on `model` is the build (routing/billing/serving) while
	// `publicModel` is echoed back so the consumer never sees the quant.
	buildModel, publicModel, modelRewritten, ok := s.resolveRequestedBuild(
		parsed, model, allowedProviderSerials, policy, aliasTraits)
	if !ok {
		s.recordRejection(rejectionInfo{
			Request:         r,
			Stage:           "model_resolution",
			ReasonCode:      "model_unavailable",
			HttpStatus:      http.StatusServiceUnavailable,
			KeyID:           requestcontext.KeyID(r.Context()),
			ConsumerKeyHash: store.HashKey(consumerKeyFromContext(r.Context())),
			RequestedModel:  model,
			Params:          rejectionSamplingParams(parsed),
		})
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_unavailable",
			fmt.Sprintf("model %q has no available build right now", model), withParam("model")))
		return
	}
	model = buildModel
	if modelRewritten {
		body.markDirty()
	}
	user := auth.UserFromContext(r.Context())
	serviceChatConsumer := r.URL.Path == "/v1/chat/completions" &&
		user != nil && user.Role == store.RoleService
	if applyResolvedModelReasoningPolicy(parsed, model, serviceChatConsumer, reasoningProvided) {
		body.markDirty()
	}

	// Shared media/tools fail-fast. Chat completions additionally rejects media
	// sent via the Responses API surface (input-without-messages), because the
	// Responses→chat lowering doesn't carry image/video parts through.
	if s.visionToolsFailFast(w, model, publicModel, requiresVision, hasTools,
		requiresToolConstraint, string(validatedMode),
		input != nil && len(messages) == 0, policy, allowedProviderSerials) {
		return
	}
	// Remote media URL gate (phase 1, pre-billing). With the media resolver
	// enabled (default), remote http(s) image_url/video_url links are fetched
	// and inlined as data: URIs AFTER the balance reservation (resolveRemoteMedia
	// below); here we fail fast only the cases that must never fetch: sealed
	// requests, remote refs in shapes the resolver doesn't handle, and the
	// resolver-disabled fallback (the legacy one-clean-400, the provider VLM
	// path being data:-only).
	if s.gateRemoteMediaPreDispatch(w, r, parsed, model, publicModel, requiresVision, hasTools) {
		return
	}

	// Inject model-specific request defaults from the registry, then apply the
	// model's max_tokens bound. Single DB lookup (cached for platform prices).
	maxOutputBound := defaultMaxOutputTokens
	// modelMaxContext is the model's max context window (0 = unknown), used by the
	// servability gate. Lifted out of the record block so it is in scope at the
	// preflight below.
	modelMaxContext := 0
	registryReadStart := time.Now()
	var resolvedRuntimeParameters map[string]any
	if rec, err := s.store.GetModelRegistryRecord(model); err == nil {
		profileDBCall(rp, registryReadStart)
		resolvedRuntimeParameters = rec.RuntimeParameters
		if runtimeDefaults.apply(parsed, rec.RuntimeParameters) {
			body.markDirty()
		}
		// Use the registry's max_output_length as the default max_tokens
		// bound instead of the hardcoded 8192. This lets models like
		// GPT-OSS 20B (32K output) generate longer responses when the
		// consumer omits max_tokens.
		if rec.MaxOutputLength > 0 {
			maxOutputBound = rec.MaxOutputLength
		}
		modelMaxContext = rec.MaxContextLength
	}
	if err := validateResolvedToolConstraintParser(
		parsed, validatedMode, model, s.registry.ModelType(model),
		resolvedRuntimeParameters,
	); err != nil {
		s.recordToolConstraintMetric(validatedMode, "compile_rejection")
		writeToolConstraintValidationError(w, err)
		return
	}

	// Bound the generation so the pre-flight reservation covers it. If the
	// consumer didn't set max_tokens, inject the model's max_output_length
	// (or defaultMaxOutputTokens as fallback). Without this bound the
	// provider could return more tokens than we reserved for, and the
	// silent post-inference charge failure would hand the consumer free
	// inference (GitHub issue #33).
	if ensureMaxTokensBound(parsed, isResponsesAPI, maxOutputBound) {
		body.markDirty()
	}

	stream, _ := parsed["stream"].(bool)
	estimatedPromptTokens := shape.routingPromptTokens(parsed)
	billingPromptTokens := shape.billingPromptTokens(parsed)
	requestedMaxTokens := estimateRequestedMaxTokens(parsed)
	deadline := s.FirstContentDeadline(model, estimatedPromptTokens)
	timing.ParsedAt = time.Now()
	rp.Mark(registry.StampReqParsed)
	if s.shedIfModelRejected(w, r, parsed, policy, publicModel, model, stream, estimatedPromptTokens, requestedMaxTokens, requiresVision, hasTools) {
		return
	}

	// Single serialization point: every rewrite above (stop, stripped fields,
	// alias, reasoning policy, runtime defaults, max_tokens) landed in parsed;
	// serialize once here — or hand the caller's exact bytes through when
	// nothing changed.
	rawBody, err := body.current()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse(
			"server_error", "failed to prepare inference request"))
		return
	}
	providerBody := rawBody
	if isResponsesAPI {
		loweredProviderBody, err := promptcontract.LowerProviderBody(promptcontract.EndpointResponses, rawBody)
		if err != nil {
			s.recordRejection(rejectionInfo{
				Request:               r,
				Stage:                 "validation",
				ReasonCode:            "bad_param",
				HttpStatus:            http.StatusBadRequest,
				KeyID:                 requestcontext.KeyID(r.Context()),
				ConsumerKeyHash:       store.HashKey(consumerKeyFromContext(r.Context())),
				RequestedModel:        publicModel,
				ResolvedModel:         model,
				Stream:                stream,
				EstimatedPromptTokens: estimatedPromptTokens,
				RequestedMaxTokens:    requestedMaxTokens,
				RequiresVision:        requiresVision,
				HasTools:              hasTools,
				Params:                rejectionSamplingParams(parsed),
			})
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", err.Error()))
			return
		}
		providerBody = loweredProviderBody
	}
	// Candidate provider bodies (the resolved build, the alias fallback build
	// the preflight probes) and the routing verdicts derived from them are
	// memoized per request: traits, the protocol-0 size verdict, and dispatch
	// all reuse one serialization per candidate. When the body above is the
	// coordinator's own serialization, the resolved build is seeded with it —
	// parsed is fully reconciled for that build, so a rebuild would produce the
	// same bytes. A verbatim caller body is NOT a substitute (its whitespace,
	// key order and escapes differ from the serialized form the size verdicts
	// have always measured), so that rare case builds its candidate as before.
	bodies := newProviderBodyMemo(func(candidateModel string) ([]byte, error) {
		return s.candidateProviderBody(parsed, runtimeDefaults, candidateModel,
			serviceChatConsumer, reasoningProvided, isResponsesAPI)
	}, hasTools, requiresVision)
	if body.serialized {
		bodies.seed(model, providerBody)
	}
	routingTraitsForModel := func(candidateModel string) registry.RequestTraits {
		traits, ok := bodies.traits(candidateModel)
		if !ok {
			traits = registry.RequestTraits{HasTools: hasTools}
		}
		traits.RequiresToolConstraint = requiresToolConstraint
		traits.ToolChoiceMode = string(validatedMode)
		traits.ToolChoiceName = toolChoiceName
		traits.ParallelToolCalls = parallelToolCalls
		return traits
	}
	providerBodyErrorForModel := bodies.sizeError
	routingTraits := routingTraitsForModel(model)

	// Per-account token rate limiting (ITPM/OTPM) — the industry-standard
	// token throttle alongside RPM. Charged upfront from the input estimate
	// and the bounded max_tokens (OpenAI-style). Runs before the balance
	// reservation so a throttled request never touches billing.
	tokenAdmission, ok := s.applyTokenRateLimitWithAdmission(w, r, estimatedPromptTokens, requestedMaxTokens)
	if !ok {
		return
	}

	// Pre-flight balance reservation + per-key spend cap (see
	// reserveInferenceBalance). Self-route and a nil billing backend are free.
	reservedMicroUSD, serviceReservation, reserveHandled := s.reserveInferenceBalance(w, r, parsed, balanceReservationParams{
		model:                 model,
		publicModel:           publicModel,
		billingPromptTokens:   billingPromptTokens,
		estimatedPromptTokens: estimatedPromptTokens,
		requestedMaxTokens:    requestedMaxTokens,
		stream:                stream,
		requiresVision:        requiresVision,
		hasTools:              hasTools,
		policy:                policy,
	})
	if reserveHandled {
		return
	}
	timing.ReservedAt = time.Now()
	rp.Mark(registry.StampReqReserved)

	// Refund reservation on early errors (before inference starts).
	refundReservation := func() {
		if reservedMicroUSD > 0 {
			s.inferenceSettlement().Release(consumerKeyFromContext(r.Context()), model, reservedMicroUSD, serviceReservation)
		}
	}

	// Reject requests for models not in the catalog.
	if !policy.Enabled && !s.registry.IsModelInCatalog(model) {
		refundReservation()
		s.recordRejection(rejectionInfo{
			Request:               r,
			Stage:                 "model_resolution",
			ReasonCode:            "model_not_found",
			HttpStatus:            http.StatusNotFound,
			KeyID:                 requestcontext.KeyID(r.Context()),
			ConsumerKeyHash:       store.HashKey(consumerKeyFromContext(r.Context())),
			RequestedModel:        publicModel,
			ResolvedModel:         model,
			Stream:                stream,
			EstimatedPromptTokens: estimatedPromptTokens,
			RequestedMaxTokens:    requestedMaxTokens,
			RequiresVision:        requiresVision,
			HasTools:              hasTools,
			Params:                rejectionSamplingParams(parsed),
		})
		writeJSON(w, http.StatusNotFound, errorResponse("model_not_found",
			fmt.Sprintf("model %q is not available — see /v1/models for supported models", publicModel), withParam("model")))
		return
	}

	// Resolve remote http(s) image_url/video_url links into inline base64 data:
	// URIs (phase 2 — see media_resolve.go) — AFTER token admission, the balance
	// reservation, and the catalog check, so network I/O is gated behind the
	// cost gates: an authenticated but unfunded/over-quota request (or one for a
	// nonexistent model) can never drive coordinator-side fetches. The token &
	// routing estimates above count media parts flatly (300/1500 per part), so
	// they don't need the inlined bytes. The billing reservation is refunded on
	// any failure, and topped up below on success — it was taken while the media
	// was still a ~100-byte URL. parsed is mutated in place, so every view
	// derived from the pre-inline body is refreshed via refreshForwardBody.
	var mediaInlined bool
	rawBody, mediaInlined, ok = s.resolveRemoteMedia(w, r, rawBody, parsed, timing, mediaResolveMeta{
		model:                 model,
		publicModel:           publicModel,
		stream:                stream,
		estimatedPromptTokens: estimatedPromptTokens,
		firstContentDeadline:  deadline,
		requestedMaxTokens:    requestedMaxTokens,
		hasTools:              hasTools,
		requiresVision:        requiresVision,
		selfRoute:             policy.Enabled,
		ownerAccountID:        policy.OwnerAccountID,
		traits:                routingTraits,
	})
	if !ok {
		refundReservation()
		// Token-rate admission is intentionally NOT refunded: this matches every
		// other post-admission validation failure and makes blocked/invalid URL
		// probes consume the caller's input/output token quota.
		return
	}

	// refreshForwardBody re-derives every view of the provider-bound request from
	// a freshly marshaled `parsed`: the threaded rawBody, the body actually
	// forwarded to the provider (re-lowered input→chat on the Responses surface,
	// which can itself fail with a 400), the memoized candidate bodies (every
	// earlier candidate described a parsed that no longer exists), and the
	// routing traits computed from it. Any in-place mutation of `parsed` MUST go
	// through it — an alias fallback rewriting the model, or remote media being
	// inlined as data: URIs. Returns false after writing a terminal response.
	refreshForwardBody := func(forwardBytes []byte, forModel string) bool {
		rawBody = forwardBytes
		body.replace(forwardBytes)
		bodies.reset()
		if !isResponsesAPI {
			providerBody = rawBody
			bodies.seed(forModel, providerBody)
			routingTraits = routingTraitsForModel(forModel)
			return true
		}
		var err error
		providerBody, err = promptcontract.LowerProviderBody(promptcontract.EndpointResponses, rawBody)
		if err != nil {
			refundReservation()
			s.recordRejection(rejectionInfo{
				Request:               r,
				Stage:                 "validation",
				ReasonCode:            "bad_param",
				HttpStatus:            http.StatusBadRequest,
				KeyID:                 requestcontext.KeyID(r.Context()),
				ConsumerKeyHash:       store.HashKey(consumerKeyFromContext(r.Context())),
				RequestedModel:        publicModel,
				ResolvedModel:         forModel,
				Stream:                stream,
				EstimatedPromptTokens: estimatedPromptTokens,
				RequestedMaxTokens:    requestedMaxTokens,
				RequiresVision:        requiresVision,
				HasTools:              hasTools,
				Params:                rejectionSamplingParams(parsed),
			})
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", err.Error()))
			return false
		}
		bodies.seed(forModel, providerBody)
		routingTraits = routingTraitsForModel(forModel)
		return true
	}

	// Remote media was fetched and inlined into `parsed` above, so `providerBody`
	// (captured before the resolve) and the routing traits derived from it now
	// describe a body that no longer exists. Without this refresh the coordinator
	// pays for the fetch and then seals and dispatches the ORIGINAL body still
	// carrying the http(s) URL, which the provider's data:-only guard rejects.
	if mediaInlined {
		if !refreshForwardBody(rawBody, model) {
			return
		}
		// The reservation was taken against a body where the image was a short
		// URL, so estimateBillingPromptTokens — the guaranteed len(bytes) >= tokens
		// upper bound the settlement path relies on — was computed over ~100 bytes
		// of URL instead of the inlined media. Re-reserve against the real body
		// before dispatch; otherwise settlement's 2x-reservation overage clamp
		// silently absorbs the difference and underpays the provider.
		var topUpHandled bool
		reservedMicroUSD, topUpHandled = s.topUpReservationForInlinedMedia(w, r, parsed, balanceReservationParams{
			model:                 model,
			publicModel:           publicModel,
			billingPromptTokens:   estimateBillingPromptTokens(parsed),
			estimatedPromptTokens: estimatedPromptTokens,
			requestedMaxTokens:    requestedMaxTokens,
			stream:                stream,
			requiresVision:        requiresVision,
			hasTools:              hasTools,
			policy:                policy,
		}, reservedMicroUSD)
		if topUpHandled {
			refundReservation()
			return
		}
	}

	// Shared routing/capacity admission preflight (self-route / prefer / public
	// capacity+TTFT gate — see runInferenceAdmission). On the chat path an alias
	// fallback must refresh the threaded rawBody; thread that as the
	// onModelFallback callback. resolvedModel uses the new build to match the
	// pre-extraction behavior.
	onModelFallback := func(newModel string) bool {
		var runtimeParameters map[string]any
		if rec, err := s.store.GetModelRegistryRecord(newModel); err == nil {
			runtimeParameters = rec.RuntimeParameters
			runtimeDefaults.apply(parsed, runtimeParameters)
		} else {
			runtimeDefaults.apply(parsed, nil)
		}
		if err := validateResolvedToolConstraintParser(
			parsed, validatedMode, newModel, s.registry.ModelType(newModel),
			runtimeParameters,
		); err != nil {
			s.recordToolConstraintMetric(validatedMode, "compile_rejection")
			writeToolConstraintValidationError(w, err)
			refundReservation()
			return false
		}
		applyResolvedModelReasoningPolicy(parsed, newModel, serviceChatConsumer, reasoningProvided)
		// maybeFallbackAlias rewrote parsed["model"]; the defaults and reasoning
		// policy above may have moved more. One serialization covers all of it.
		body.markDirty()
		forwardBytes, err := body.current()
		if err != nil {
			refundReservation()
			writeJSON(w, http.StatusInternalServerError, errorResponse(
				"server_error", "failed to prepare inference request"))
			return false
		}
		return refreshForwardBody(forwardBytes, newModel)
	}
	var preflightHandled bool
	preflightStart := time.Now()
	model, preflightHandled = s.runInferenceAdmission(w, r, parsed, inferenceAdmissionParams{
		model:                     model,
		publicModel:               publicModel,
		stream:                    stream,
		estimatedPromptTokens:     estimatedPromptTokens,
		requestedMaxTokens:        requestedMaxTokens,
		requiresVision:            requiresVision,
		hasTools:                  hasTools,
		traits:                    &routingTraits,
		traitsForModel:            routingTraitsForModel,
		providerBodyErrorForModel: providerBodyErrorForModel,
		modelMaxContext:           modelMaxContext,
		allowedProviderSerials:    allowedProviderSerials,
		deadline:                  deadline,
		policy:                    policy,
		refundReservation:         refundReservation,
		onModelFallback:           onModelFallback,
	})
	if rp != nil {
		rp.PreflightUS = time.Since(preflightStart).Microseconds()
		rp.Mark(registry.StampReqPreflightDone)
		if preflightHandled {
			rp.PreflightOutcome = "handled"
		} else {
			rp.PreflightOutcome = "passed"
		}
	}
	if preflightHandled {
		return
	}

	// Dispatch to a provider with speculative TTFT-aware dispatch. On the
	// first attempt we dispatch to the best provider (primary), and start a
	// speculative timer at 50% of the TTFT deadline. If the primary hasn't
	// produced a first chunk by the speculative timer, a backup provider is
	// dispatched in parallel and both race. If the primary fails outright
	// (error before the speculative timer), up to maxDispatchAttempts
	// sequential retries are performed without speculation.
	//
	// No HTTP response is written until a provider starts generating, so
	// retries and speculative dispatch are invisible to the consumer.
	// Dispatch is driven by the per-request state machine in dispatch.go: it
	// picks a provider (or queues), runs the speculative TTFT-aware first-chunk
	// wait with an invisible backup race + failover up to maxDispatchAttempts,
	// commits exactly once, then writes attestation/timing headers and streams.
	consumerKey := consumerKeyFromContext(r.Context())
	consumerLocation := s.requestLocation(r)

	// model may have been rewritten by a capacity- or TTFT-fallback above
	// (maybeFallbackAlias), so refresh the context
	// window for the FINAL build before handing it to the dispatch loop — otherwise
	// shouldStopFailover/classifyRejection would compare a provider's budget against
	// the originally-resolved model's context. Overwrite only on a successful lookup
	// (fallback builds of the same alias normally share a context window; a build
	// absent from the store keeps the prior value, matching the initial read).
	registryReadStart2 := time.Now()
	if rec, err := s.store.GetModelRegistryRecord(model); err == nil {
		modelMaxContext = rec.MaxContextLength
	}
	profileDBCall(rp, registryReadStart2)
	cachePlan := s.planCacheRoute(
		r.Context(), consumerKey, model, providerBody, requiresVision)
	rp.Mark(registry.StampReqPlanDone)
	if rp != nil {
		rp.Model, rp.PublicModel, rp.Stream = model, publicModel, stream
		rp.FirstContentBudgetMs = int(deadline.Milliseconds())
		rp.EstimatedPromptTokens, rp.RequestedMaxTokens = estimatedPromptTokens, requestedMaxTokens
		rp.RequiresVision, rp.HasTools = requiresVision, hasTools
		rp.BodyBytes = len(rawBody)
		if mediaInlined {
			rp.Mark(registry.StampReqMediaFetched)
		}
	}

	s.inferenceDispatch().Run(w, r, dispatch.Request{
		Model:                  model,
		PublicModel:            publicModel,
		RawBody:                providerBody,
		ConsumerKey:            consumerKey,
		ConsumerLocation:       consumerLocation,
		ReservedMicroUSD:       reservedMicroUSD,
		TokenAdmission:         tokenAdmission,
		ServiceReservation:     serviceReservation,
		EstimatedPromptTokens:  estimatedPromptTokens,
		RequestedMaxTokens:     requestedMaxTokens,
		RequiresVision:         requiresVision,
		VisionImageCount:       shape.mediaParts,
		HasTools:               hasTools,
		RequiresToolConstraint: requiresToolConstraint,
		ToolChoiceMode:         string(validatedMode),
		ToolChoiceName:         toolChoiceName,
		ParallelToolCalls:      parallelToolCalls,
		IsResponsesAPI:         isResponsesAPI,
		Stream:                 stream,
		MetadataDetails:        response.MetadataDetailsFromRequest(r),
		Policy:                 policy,
		AllowedProviderSerials: allowedProviderSerials,
		CachePlan:              cachePlan,
		Timing:                 timing,
		Profile:                rp,
		Deadline:               deadline,
		SpeculativeAt:          time.Duration(float64(deadline) * dispatch.SpeculativeTimerRatio),
		ModelMaxContext:        modelMaxContext,
		RefundReservation:      refundReservation,
	})
}

// createAPIKeyRequest is the POST /v1/keys (and rotate inherit) body. Money is
// supplied in USD; the wire never sees the secret after the create response.
type createAPIKeyRequest struct {
	Name          string     `json:"name"`
	LimitUSD      *float64   `json:"limit_usd"`
	LimitReset    string     `json:"limit_reset"`
	RPMLimit      *int64     `json:"rpm_limit"`
	ITPMLimit     *int64     `json:"itpm_limit"`
	OTPMLimit     *int64     `json:"otpm_limit"`
	AllowedModels []string   `json:"allowed_models"`
	SelfRouteOnly bool       `json:"self_route_only"`
	ExpiresAt     *time.Time `json:"expires_at"`
}

// usdToMicro converts a USD dollar amount to micro-USD (rounded).
func usdToMicro(usd float64) int64 { return int64(math.Round(usd * 1_000_000)) }

// microToUSD converts micro-USD to a USD float.
func microToUSD(micro int64) float64 { return float64(micro) / 1_000_000 }

// handleHealth handles GET /health.
// Returns the coordinator's status and the number of connected providers.
// This endpoint does not require authentication.
//
// /health is a LIVENESS probe: it returns 200 whenever the process is up, INCLUDING
// while draining. This is deliberate. The production host Caddy health-checks its
// single coordinator upstream on /health with health_status 200, so returning 503 here
// would mark the only backend down and make the admin/rollback endpoints
// (POST /v1/admin/drain {"draining":false}) and /readyz unreachable through the
// public URL — you could not undo a drain remotely. Drain/readiness lives on
// /readyz (handleReadyz, 503 while draining), which the deploy script and
// multi-backend load balancers consult to shift traffic. The body still reports
// draining=true for observability, but the status code stays 200.
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, types.HealthResponse{
		Status:      "ok",
		Draining:    s.IsDraining(),
		Providers:   s.registry.ProviderCount(),
		Version:     BuildVersion,
		BuildCommit: BuildCommit,
		BuildDate:   BuildDate,
	})
}

// handleVersion returns the latest provider CLI version and download URL.
// Providers call GET /api/version to check if they need to update.
// If a release is registered in the store, uses that. Otherwise falls back
// to the hardcoded LatestProviderVersion.
func (s *Server) handleVersion(w http.ResponseWriter, r *http.Request) {
	if cached, ok := s.readCache.Get(apiVersionCacheKey); ok {
		writeCachedJSON(w, cached)
		return
	}

	var resp types.VersionResponse
	// Try release table first.
	if release := s.store.GetLatestRelease(defaultReleasePlatform); release != nil {
		resp = types.VersionResponse{
			Version:      release.Version,
			Platform:     release.Platform,
			Backend:      release.Backend,
			DownloadURL:  release.URL,
			BinaryHash:   release.BinaryHash,
			BundleHash:   release.BundleHash,
			MetallibHash: release.MetallibHash,
			Changelog:    release.Changelog,
		}
	} else {
		// Fallback to hardcoded version + coordinator download.
		scheme := "https"
		if r.TLS == nil && !strings.Contains(r.Host, "darkbloom.dev") {
			scheme = "http"
		}
		downloadURL := fmt.Sprintf("%s://%s/dl/eigeninference-bundle-macos-arm64.tar.gz", scheme, r.Host)
		resp = types.VersionResponse{
			Version:     LatestProviderVersion,
			DownloadURL: downloadURL,
		}
	}
	body, err := json.Marshal(resp)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to encode version"))
		return
	}
	s.readCache.Set(apiVersionCacheKey, body, time.Minute)
	writeCachedJSON(w, body)
}

// --- payment handlers ---

// handleBalance handles GET /v1/payments/balance.
// Returns the consumer's current balance in both micro-USD and USD.
func (s *Server) handleBalance(w http.ResponseWriter, r *http.Request) {
	consumerKey := consumerKeyFromContext(r.Context())
	balance := s.ledger.Balance(consumerKey)
	withdrawable := s.store.GetWithdrawableBalance(consumerKey)

	writeJSON(w, http.StatusOK, types.BalanceResponse{
		BalanceMicroUSD:      balance,
		BalanceUSD:           fmt.Sprintf("%.6f", float64(balance)/1_000_000),
		WithdrawableMicroUSD: withdrawable,
		WithdrawableUSD:      fmt.Sprintf("%.6f", float64(withdrawable)/1_000_000),
	})
}

// handleUsage handles GET /v1/payments/usage.
// Returns the consumer's inference usage history with per-request costs.
// Tries in-memory ledger first (has full detail), falls back to store
// ledger history (persists across restarts but has less detail).
func (s *Server) handleUsage(w http.ResponseWriter, r *http.Request) {
	consumerKey := consumerKeyFromContext(r.Context())
	entries := s.ledger.Usage(consumerKey)

	// If in-memory usage is empty (coordinator restarted), build from
	// the persisted usage table which has full request details.
	if len(entries) == 0 {
		usageRecords := s.store.UsageByConsumer(consumerKey)
		for _, u := range usageRecords {
			jobID := u.RequestID
			if jobID == "" {
				jobID = u.ProviderID
			}
			model := u.Model
			if u.PublicModel != "" {
				model = u.PublicModel
			}
			entries = append(entries, payments.UsageEntry{
				JobID:            jobID,
				Model:            model,
				PromptTokens:     u.PromptTokens,
				CompletionTokens: u.CompletionTokens,
				CostMicroUSD:     u.CostMicroUSD,
				Timestamp:        u.CreatedAt,
			})
		}
	}

	writeJSON(w, http.StatusOK, types.UsageResponse{
		Usage: entries,
	})
}

// handleProviderEarnings handles GET /v1/provider/earnings?wallet=0x...
//
// Returns the provider's balance and payout history.
// No API key auth required — providers identify by provider address.
func (s *Server) handleProviderEarnings(w http.ResponseWriter, r *http.Request) {
	wallet := r.URL.Query().Get("wallet")
	if wallet == "" {
		wallet = r.Header.Get("X-Provider-Wallet")
	}
	if wallet == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "wallet address required (query param ?wallet=0x... or X-Provider-Wallet header)"))
		return
	}

	// Look up balance by provider address
	balance := s.ledger.Balance(wallet)
	history := s.ledger.LedgerHistory(wallet)
	payouts := s.ledger.AllPayouts()

	// Filter payouts to this wallet
	var walletPayouts []payments.Payout
	var totalEarned int64
	var totalJobs int
	for _, p := range payouts {
		if p.ProviderAddress == wallet {
			walletPayouts = append(walletPayouts, p)
			totalEarned += p.AmountMicroUSD
			totalJobs++
		}
	}

	// If no explicit payout records exist (for example, legacy rows created
	// before provider_payouts was introduced), reconstruct from persisted
	// ledger entries with payout type and the wallet as account ID.
	if len(walletPayouts) == 0 {
		ledgerEntries := s.store.LedgerHistory(wallet)
		for _, le := range ledgerEntries {
			if le.Type == store.LedgerPayout && le.Reference != "" {
				walletPayouts = append(walletPayouts, payments.Payout{
					ProviderAddress: wallet,
					AmountMicroUSD:  le.AmountMicroUSD,
					JobID:           le.Reference,
					Timestamp:       le.CreatedAt,
					Settled:         true,
				})
				totalEarned += le.AmountMicroUSD
				totalJobs++
			}
		}
	}

	if walletPayouts == nil {
		walletPayouts = []payments.Payout{}
	}

	writeJSON(w, http.StatusOK, types.ProviderEarningsResponse{
		BalanceMicroUSD:     balance,
		BalanceUSD:          fmt.Sprintf("%.6f", float64(balance)/1_000_000),
		TotalEarnedMicroUSD: totalEarned,
		TotalEarnedUSD:      fmt.Sprintf("%.6f", float64(totalEarned)/1_000_000),
		TotalJobs:           totalJobs,
		Payouts:             walletPayouts,
		Ledger:              history,
	})
}

// --- helpers ---

// handleCompletions handles POST /v1/completions.
// Proxies OpenAI-compatible text completions to the selected provider over the
// E2E-encrypted WebSocket relay (MLX-Swift in-process backend).
func (s *Server) handleCompletions(w http.ResponseWriter, r *http.Request) {
	s.handleGenericInference(w, r, "/v1/completions")
}

// handleAnthropicMessages handles POST /v1/messages.
// Proxies the Anthropic-compatible messages API to the selected provider over
// the E2E-encrypted WebSocket relay (MLX-Swift in-process backend).
func (s *Server) handleAnthropicMessages(w http.ResponseWriter, r *http.Request) {
	s.handleGenericInference(w, r, "/v1/messages")
}

// handleGenericInference is the shared dispatch for completions and Anthropic endpoints.
// It reads the endpoint-native body, preserves it for accounting, lowers the
// final provider body to OpenAI chat format, and reuses the same E2E encryption
// and provider routing as chat completions.
func (s *Server) handleGenericInference(w http.ResponseWriter, r *http.Request, endpoint string) {
	timing := &registry.RequestTiming{ReceivedAt: time.Now()}
	rp := s.newRequestProfile(r, "", "", false)

	// Shared prelude: read body, normalize tool schemas (Anthropic /v1/messages
	// bodies carry a top-level "tools" array too; the provider body is rebuilt
	// from parsed below, so normalizing before the unmarshal covers it), parse,
	// require a model, enforce the per-key model allowlist.
	prelude, ok := s.parseInferencePrelude(w, r)
	if !ok {
		return
	}
	// This handler rebuilds its provider body from `parsed` (inferenceBody
	// below); the prelude's forward bytes are only threaded into
	// resolveRequestedModel, which never uses them here.
	rawBody := prelude.originalRawBody
	originalRawBody := prelude.originalRawBody
	parsed := prelude.parsed
	model := prelude.model
	runtimeDefaults := newModelRuntimeDefaults(parsed)
	endpointKind := promptcontract.EndpointCompletions
	if endpoint == "/v1/messages" {
		endpointKind = promptcontract.EndpointMessages
	}

	var allowedProviderSerials []string
	stripProviderRoutingFields(parsed)
	response.ApplyMetadataDetailsRequest(r, parsed)

	// "Use my own machine, for free" opt-in (see handleChatCompletions).
	policy := s.resolveSelfRoutePolicy(r)

	// Constraint validation needs the lowered chat shape. Endpoint-native
	// shapes the contract lowering cannot express — multi-prompt completions,
	// media-bearing messages — have always been forwarded verbatim (see the
	// inferenceBody fallback below), so a lowering failure is only terminal
	// for requests that actually carry tool policy to validate; tool-less
	// unsupported shapes keep the pre-existing native-forward behavior with
	// the neutral auto defaults.
	validatedPolicy := toolpolicy.Policy{
		Mode: toolpolicy.Auto, Parallel: true,
	}
	constraintBody, constraintLowerErr := promptcontract.LowerProviderBody(
		endpointKind, originalRawBody)
	if constraintLowerErr == nil {
		var validationErr error
		validatedPolicy, validationErr = toolpolicy.ValidateBytes(constraintBody)
		if validationErr != nil {
			s.recordToolConstraintMetric(validatedPolicy.Mode, "compile_rejection")
			writeToolConstraintValidationError(w, validationErr)
			return
		}
	} else if _, hasToolChoice := parsed["tool_choice"]; hasToolChoice || requestHasTools(parsed) {
		s.recordToolConstraintMetric(validatedPolicy.Mode, "compile_rejection")
		writeJSON(w, http.StatusBadRequest, errorResponse(
			"invalid_request_error", constraintLowerErr.Error()))
		return
	}
	validatedMode := validatedPolicy.Mode
	toolChoiceName := validatedPolicy.Name
	parallelToolCalls := validatedPolicy.Parallel
	s.recordToolConstraintMetric(validatedMode, "requested")
	requiresToolConstraint := validatedMode.RequiresInferenceConstraint()
	requiresVision := detectMediaRequirement(parsed)
	hasTools := requestHasTools(parsed)
	aliasTraits := registry.RequestTraits{
		HasTools:               hasTools,
		RequiresToolConstraint: requiresToolConstraint,
		ToolChoiceMode:         string(validatedMode),
		ToolChoiceName:         toolChoiceName,
		ParallelToolCalls:      parallelToolCalls,
	}

	// Resolve a public alias to a concrete build id, constraint-aware (after
	// allowlist/self-route are known). resolveRequestedModel rewrites
	// parsed["model"] to the build; this handler builds the provider body fresh
	// from `parsed` (inferenceBody below), so rawBody isn't threaded here.
	buildModel, publicModel, _, ok := s.resolveRequestedModel(
		parsed, rawBody, model, allowedProviderSerials, policy, aliasTraits)
	if !ok {
		s.recordRejection(rejectionInfo{
			Request:         r,
			Stage:           "model_resolution",
			ReasonCode:      "model_unavailable",
			HttpStatus:      http.StatusServiceUnavailable,
			KeyID:           requestcontext.KeyID(r.Context()),
			ConsumerKeyHash: store.HashKey(consumerKeyFromContext(r.Context())),
			RequestedModel:  model,
			Params:          rejectionSamplingParams(parsed),
		})
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_unavailable",
			fmt.Sprintf("model %q has no available build right now", model), withParam("model")))
		return
	}
	model = buildModel

	if !policy.Enabled && !s.registry.IsModelInCatalog(model) {
		s.recordRejection(rejectionInfo{
			Request:         r,
			Stage:           "model_resolution",
			ReasonCode:      "model_not_found",
			HttpStatus:      http.StatusNotFound,
			KeyID:           requestcontext.KeyID(r.Context()),
			ConsumerKeyHash: store.HashKey(consumerKeyFromContext(r.Context())),
			RequestedModel:  publicModel,
			ResolvedModel:   model,
			Params:          rejectionSamplingParams(parsed),
		})
		writeJSON(w, http.StatusNotFound, errorResponse("model_not_found",
			fmt.Sprintf("model %q is not available — see /v1/models for supported models", publicModel), withParam("model")))
		return
	}
	// Shared media/tools fail-fast (see visionToolsFailFast). Completions and
	// Anthropic bodies share the top-level "tools" field; neither has the
	// Responses-API media surface, so rejectResponsesMedia is false here.
	if s.visionToolsFailFast(w, model, publicModel, requiresVision, hasTools,
		requiresToolConstraint, string(validatedMode),
		false, policy, allowedProviderSerials) {
		return
	}
	if s.rejectRemoteMediaURLs(w, r, parsed, model, publicModel, requiresVision, hasTools) {
		return
	}

	// Completions and Anthropic messages both use the max_tokens field (never
	// max_output_tokens, which is Responses API only). Inject a default if
	// unset so the pre-flight reservation bounds the generation.
	genericMaxOutput := defaultMaxOutputTokens
	modelMaxContext := 0
	if rec, err := s.store.GetModelRegistryRecord(model); err == nil {
		// Keep generic endpoints aligned with chat completions: parser defaults
		// are catalog-owned request semantics, not provider inference guesses.
		runtimeDefaults.apply(parsed, rec.RuntimeParameters)
		if rec.MaxOutputLength > 0 {
			genericMaxOutput = rec.MaxOutputLength
		}
		modelMaxContext = rec.MaxContextLength
	}
	ensureMaxTokensBound(parsed, false, genericMaxOutput)

	stream, _ := parsed["stream"].(bool)
	estimatedPromptTokens := estimatePromptTokens(parsed)
	billingPromptTokens := estimateBillingPromptTokens(parsed)
	requestedMaxTokens := estimateRequestedMaxTokens(parsed)
	genericDeadline := s.FirstContentDeadline(model, estimatedPromptTokens)
	timing.ParsedAt = time.Now()
	rp.Mark(registry.StampReqParsed)
	if s.shedIfModelRejected(w, r, parsed, policy, publicModel, model, stream, estimatedPromptTokens, requestedMaxTokens, requiresVision, hasTools) {
		return
	}

	// Bind the endpoint to the cache-planning input. Successful lowering removes
	// it from the final OpenAI chat body before that body is sealed.
	parsed["endpoint"] = endpoint

	// Per-account token rate limiting (ITPM/OTPM), before the reservation.
	tokenAdmission, ok := s.applyTokenRateLimitWithAdmission(w, r, estimatedPromptTokens, requestedMaxTokens)
	if !ok {
		return
	}

	// Pre-flight balance reservation + per-key spend cap (see
	// reserveInferenceBalance). Self-route and a nil billing backend are free.
	consumerKey := consumerKeyFromContext(r.Context())
	consumerLocation := s.requestLocation(r)
	reservedMicroUSD, serviceReservation, reserveHandled := s.reserveInferenceBalance(w, r, parsed, balanceReservationParams{
		model:                 model,
		publicModel:           publicModel,
		billingPromptTokens:   billingPromptTokens,
		estimatedPromptTokens: estimatedPromptTokens,
		requestedMaxTokens:    requestedMaxTokens,
		stream:                stream,
		requiresVision:        requiresVision,
		hasTools:              hasTools,
		policy:                policy,
	})
	if reserveHandled {
		return
	}
	refundReservation := func() {
		if reservedMicroUSD > 0 {
			s.inferenceSettlement().Release(consumerKey, model, reservedMicroUSD, serviceReservation)
		}
	}
	timing.ReservedAt = time.Now()
	rp.Mark(registry.StampReqReserved)

	lowerGenericBodyForModel := func(candidateModel string) ([]byte, []byte, error) {
		candidateParsed := make(map[string]any, len(parsed))
		for key, value := range parsed {
			candidateParsed[key] = value
		}
		candidateParsed["model"] = candidateModel
		candidateDefaults := runtimeDefaults
		if rec, err := s.store.GetModelRegistryRecord(candidateModel); err == nil {
			candidateDefaults.apply(candidateParsed, rec.RuntimeParameters)
		} else {
			candidateDefaults.apply(candidateParsed, nil)
		}
		endpointBody, _ := marshalForwardBody(candidateParsed)
		inferenceBody, loweringErr := promptcontract.LowerProviderBody(
			endpointKind, endpointBody)
		if loweringErr != nil {
			inferenceBody = endpointBody
		}
		return endpointBody, inferenceBody, loweringErr
	}
	routingTraitsForModel := func(candidateModel string) registry.RequestTraits {
		_, candidateBody, _ := lowerGenericBodyForModel(candidateModel)
		traits, _ := dispatch.RoutingTraitsForProviderBody(
			hasTools, candidateBody, requiresVision)
		traits.RequiresToolConstraint = requiresToolConstraint
		traits.ToolChoiceMode = string(validatedMode)
		traits.ToolChoiceName = toolChoiceName
		traits.ParallelToolCalls = parallelToolCalls
		return traits
	}
	providerBodyErrorForModel := func(candidateModel string) error {
		_, candidateBody, _ := lowerGenericBodyForModel(candidateModel)
		_, sizeErr := dispatch.RoutingTraitsForProviderBody(
			hasTools, candidateBody, requiresVision)
		return sizeErr
	}
	var endpointBody, inferenceBody []byte
	var loweringErr error
	routingTraits := routingTraitsForModel(model)
	refreshGenericBody := func(newModel string) bool {
		var runtimeParameters map[string]any
		if rec, err := s.store.GetModelRegistryRecord(newModel); err == nil {
			runtimeParameters = rec.RuntimeParameters
			runtimeDefaults.apply(parsed, runtimeParameters)
		} else {
			runtimeDefaults.apply(parsed, nil)
		}
		if err := validateResolvedToolConstraintParser(
			parsed, validatedMode, newModel, s.registry.ModelType(newModel),
			runtimeParameters,
		); err != nil {
			s.recordToolConstraintMetric(validatedMode, "compile_rejection")
			writeToolConstraintValidationError(w, err)
			refundReservation()
			return false
		}
		endpointBody, inferenceBody, loweringErr = lowerGenericBodyForModel(newModel)
		routingTraits, _ = dispatch.RoutingTraitsForProviderBody(
			hasTools, inferenceBody, requiresVision)
		routingTraits.RequiresToolConstraint = requiresToolConstraint
		routingTraits.ToolChoiceMode = string(validatedMode)
		routingTraits.ToolChoiceName = toolChoiceName
		routingTraits.ParallelToolCalls = parallelToolCalls
		return true
	}
	if !refreshGenericBody(model) {
		return
	}

	// Shared routing/capacity admission preflight (self-route / prefer / public
	// capacity+TTFT gate — see runInferenceAdmission).
	var preflightHandled bool
	preflightStart := time.Now()
	model, preflightHandled = s.runInferenceAdmission(w, r, parsed, inferenceAdmissionParams{
		model:                     model,
		publicModel:               publicModel,
		stream:                    stream,
		estimatedPromptTokens:     estimatedPromptTokens,
		requestedMaxTokens:        requestedMaxTokens,
		requiresVision:            requiresVision,
		hasTools:                  hasTools,
		traits:                    &routingTraits,
		traitsForModel:            routingTraitsForModel,
		providerBodyErrorForModel: providerBodyErrorForModel,
		modelMaxContext:           modelMaxContext,
		allowedProviderSerials:    allowedProviderSerials,
		deadline:                  genericDeadline,
		policy:                    policy,
		refundReservation:         refundReservation,
		onModelFallback:           refreshGenericBody,
	})
	if rp != nil {
		rp.PreflightUS = time.Since(preflightStart).Microseconds()
		rp.Mark(registry.StampReqPreflightDone)
		if preflightHandled {
			rp.PreflightOutcome = "handled"
		} else {
			rp.PreflightOutcome = "passed"
		}
	}
	if preflightHandled {
		return
	}
	cachePlan := registry.CachePlan{}
	// Response framing is determined by the caller-facing endpoint, never by
	// whether its request shape could be lowered for cache participation.
	consumerEndpoint, requestedStopSequences := response.GenericResponseMetadata(endpoint, parsed)
	if loweringErr == nil {
		cachePlan = s.planCacheRoute(
			r.Context(), consumerKey, model, inferenceBody, requiresVision)
	} else {
		// Endpoint lowering is a cache-routing eligibility boundary, not a new
		// inference rejection. Preserve the existing generic endpoint behavior
		// for unsupported shapes while declining cache participation.
		inferenceBody = endpointBody
	}

	// Generic endpoints use the same dispatch state machine as chat. This keeps
	// queue deadlines, speculative failover, pre-content boilerplate handling,
	// typed deadline refusals, and terminal 429 semantics identical.
	genericRegistryReadStart := time.Now()
	if rec, err := s.store.GetModelRegistryRecord(model); err == nil {
		modelMaxContext = rec.MaxContextLength
	}
	profileDBCall(rp, genericRegistryReadStart)
	rp.Mark(registry.StampReqPlanDone)
	if rp != nil {
		rp.Model, rp.PublicModel, rp.Stream = model, publicModel, stream
		rp.FirstContentBudgetMs = int(genericDeadline.Milliseconds())
		rp.EstimatedPromptTokens, rp.RequestedMaxTokens = estimatedPromptTokens, requestedMaxTokens
		rp.RequiresVision, rp.HasTools = requiresVision, hasTools
		rp.BodyBytes = len(rawBody)
	}
	s.inferenceDispatch().Run(w, r, dispatch.Request{
		Model:                  model,
		PublicModel:            publicModel,
		RawBody:                inferenceBody,
		ConsumerKey:            consumerKey,
		ConsumerLocation:       consumerLocation,
		ReservedMicroUSD:       reservedMicroUSD,
		TokenAdmission:         tokenAdmission,
		ServiceReservation:     serviceReservation,
		EstimatedPromptTokens:  estimatedPromptTokens,
		RequestedMaxTokens:     requestedMaxTokens,
		RequiresVision:         requiresVision,
		VisionImageCount:       countMediaParts(parsed),
		HasTools:               hasTools,
		RequiresToolConstraint: requiresToolConstraint,
		ToolChoiceMode:         string(validatedMode),
		ToolChoiceName:         toolChoiceName,
		ParallelToolCalls:      parallelToolCalls,
		ConsumerEndpoint:       consumerEndpoint,
		RequestedStopSequences: requestedStopSequences,
		Stream:                 stream,
		MetadataDetails:        response.MetadataDetailsFromRequest(r),
		Policy:                 policy,
		AllowedProviderSerials: allowedProviderSerials,
		CachePlan:              cachePlan,
		Timing:                 timing,
		Profile:                rp,
		Deadline:               genericDeadline,
		SpeculativeAt:          time.Duration(float64(genericDeadline) * dispatch.SpeculativeTimerRatio),
		ModelMaxContext:        modelMaxContext,
		RefundReservation:      refundReservation,
	})
}
