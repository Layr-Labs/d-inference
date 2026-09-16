package ingress

import (
	"fmt"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/inference/response"
	"github.com/eigeninference/d-inference/coordinator/inference/toolpolicy"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// ChatCompletions handles POST /v1/chat/completions and POST /v1/responses.
//
// This is the main inference endpoint. It validates the request, finds an
// available provider for the requested model, forwards the request via
// WebSocket, and either streams SSE chunks or assembles a complete response.
//
// Chat-completions bodies are passed through to the provider, preserving all
// OpenAI-compatible fields. Responses API bodies are lowered into that same
// provider-facing chat shape while their original parsed form remains the
// source for accounting and consumer-facing response conversion.
func (s *Controller) ChatCompletions(w http.ResponseWriter, r *http.Request) {
	timing := &registry.RequestTiming{ReceivedAt: time.Now()}
	rp := s.deps.Observer.NewProfile(r, "", "", false)

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
		s.deps.Observer.Rejection(dispatch.Rejection{
			Request:         r,
			Stage:           "validation",
			ReasonCode:      "messages_required",
			HttpStatus:      http.StatusBadRequest,
			KeyID:           requestcontext.KeyID(r.Context()),
			ConsumerKeyHash: store.HashKey(requestcontext.AccountID(r.Context())),
			RequestedModel:  model,
			Params:          rejectionSamplingParams(parsed),
		})
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "messages or input is required"))
		return
	}

	// Multiple choices per request are not supported — fail loudly instead of
	// silently returning a single choice the consumer didn't ask for.
	if copies, ok := intFromRequestValue(parsed["n"]); ok && copies > 1 {
		s.deps.Observer.Rejection(dispatch.Rejection{
			Request:         r,
			Stage:           "validation",
			ReasonCode:      "bad_param",
			HttpStatus:      http.StatusBadRequest,
			KeyID:           requestcontext.KeyID(r.Context()),
			ConsumerKeyHash: store.HashKey(requestcontext.AccountID(r.Context())),
			RequestedModel:  model,
			N:               copies,
			Params:          rejectionSamplingParams(parsed),
		})
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error",
			"n > 1 is not supported", httpresponse.WithParam("n")))
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
	policy := ResolveSelfRoutePolicy(r)

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
			httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody(
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
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody(
			"invalid_request_error",
			"inference-enforced tool_choice is not supported for multimodal requests",
			httpresponse.WithParam("tool_choice")))
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
		s.deps.Observer.Rejection(dispatch.Rejection{
			Request:         r,
			Stage:           "model_resolution",
			ReasonCode:      "model_unavailable",
			HttpStatus:      http.StatusServiceUnavailable,
			KeyID:           requestcontext.KeyID(r.Context()),
			ConsumerKeyHash: store.HashKey(requestcontext.AccountID(r.Context())),
			RequestedModel:  model,
			Params:          rejectionSamplingParams(parsed),
		})
		httpresponse.WriteJSON(w, http.StatusServiceUnavailable, httpresponse.ErrorBody("model_unavailable",
			fmt.Sprintf("model %q has no available build right now", model), httpresponse.WithParam("model")))
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
	if rec, err := s.deps.Store().GetModelRegistryRecord(model); err == nil {
		s.deps.Observer.DBCall(rp, registryReadStart)
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
		parsed, validatedMode, model, s.deps.Registry().ModelType(model),
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
	requestedMaxTokens, ok := s.validateRequestedMaxTokens(w, r, parsed, model, publicModel)
	if !ok {
		return
	}
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
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody(
			"server_error", "failed to prepare inference request"))
		return
	}
	providerBody := rawBody
	if isResponsesAPI {
		loweredProviderBody, err := promptcontract.LowerProviderBody(promptcontract.EndpointResponses, rawBody)
		if err != nil {
			s.deps.Observer.Rejection(dispatch.Rejection{
				Request:               r,
				Stage:                 "validation",
				ReasonCode:            "bad_param",
				HttpStatus:            http.StatusBadRequest,
				KeyID:                 requestcontext.KeyID(r.Context()),
				ConsumerKeyHash:       store.HashKey(requestcontext.AccountID(r.Context())),
				RequestedModel:        publicModel,
				ResolvedModel:         model,
				Stream:                stream,
				EstimatedPromptTokens: estimatedPromptTokens,
				RequestedMaxTokens:    requestedMaxTokens,
				RequiresVision:        requiresVision,
				HasTools:              hasTools,
				Params:                rejectionSamplingParams(parsed),
			})
			httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", err.Error()))
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
			s.deps.Settlement().Release(requestcontext.AccountID(r.Context()), model, reservedMicroUSD, serviceReservation)
		}
	}

	// Reject requests for models not in the catalog.
	if !policy.Enabled && !s.deps.Registry().IsModelInCatalog(model) {
		refundReservation()
		s.deps.Observer.Rejection(dispatch.Rejection{
			Request:               r,
			Stage:                 "model_resolution",
			ReasonCode:            "model_not_found",
			HttpStatus:            http.StatusNotFound,
			KeyID:                 requestcontext.KeyID(r.Context()),
			ConsumerKeyHash:       store.HashKey(requestcontext.AccountID(r.Context())),
			RequestedModel:        publicModel,
			ResolvedModel:         model,
			Stream:                stream,
			EstimatedPromptTokens: estimatedPromptTokens,
			RequestedMaxTokens:    requestedMaxTokens,
			RequiresVision:        requiresVision,
			HasTools:              hasTools,
			Params:                rejectionSamplingParams(parsed),
		})
		httpresponse.WriteJSON(w, http.StatusNotFound, httpresponse.ErrorBody("model_not_found",
			fmt.Sprintf("model %q is not available — see /v1/models for supported models", publicModel), httpresponse.WithParam("model")))
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
			s.deps.Observer.Rejection(dispatch.Rejection{
				Request:               r,
				Stage:                 "validation",
				ReasonCode:            "bad_param",
				HttpStatus:            http.StatusBadRequest,
				KeyID:                 requestcontext.KeyID(r.Context()),
				ConsumerKeyHash:       store.HashKey(requestcontext.AccountID(r.Context())),
				RequestedModel:        publicModel,
				ResolvedModel:         forModel,
				Stream:                stream,
				EstimatedPromptTokens: estimatedPromptTokens,
				RequestedMaxTokens:    requestedMaxTokens,
				RequiresVision:        requiresVision,
				HasTools:              hasTools,
				Params:                rejectionSamplingParams(parsed),
			})
			httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", err.Error()))
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
		if rec, err := s.deps.Store().GetModelRegistryRecord(newModel); err == nil {
			runtimeParameters = rec.RuntimeParameters
			runtimeDefaults.apply(parsed, runtimeParameters)
		} else {
			runtimeDefaults.apply(parsed, nil)
		}
		if err := validateResolvedToolConstraintParser(
			parsed, validatedMode, newModel, s.deps.Registry().ModelType(newModel),
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
			httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody(
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
	consumerKey := requestcontext.AccountID(r.Context())
	consumerLocation := s.deps.Observer.RequestLocation(r)

	// model may have been rewritten by a capacity- or TTFT-fallback above
	// (maybeFallbackAlias), so refresh the context
	// window for the FINAL build before handing it to the dispatch loop — otherwise
	// shouldStopFailover/classifyRejection would compare a provider's budget against
	// the originally-resolved model's context. Overwrite only on a successful lookup
	// (fallback builds of the same alias normally share a context window; a build
	// absent from the store keeps the prior value, matching the initial read).
	registryReadStart2 := time.Now()
	if rec, err := s.deps.Store().GetModelRegistryRecord(model); err == nil {
		modelMaxContext = rec.MaxContextLength
	}
	s.deps.Observer.DBCall(rp, registryReadStart2)
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

	s.deps.Dispatch().Run(w, r, dispatch.Request{
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
