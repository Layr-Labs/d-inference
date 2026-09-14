package ingress

import (
	"fmt"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/inference/response"
	"github.com/eigeninference/d-inference/coordinator/inference/toolpolicy"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// handleGenericInference is the shared dispatch for completions and Anthropic endpoints.
// It reads the endpoint-native body, preserves it for accounting, lowers the
// final provider body to OpenAI chat format, and reuses the same E2E encryption
// and provider routing as chat completions.
func (s *Controller) handleGenericInference(w http.ResponseWriter, r *http.Request, endpoint string) {
	timing := &registry.RequestTiming{ReceivedAt: time.Now()}
	rp := s.deps.Observer.NewProfile(r, "", "", false)

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
	policy := ResolveSelfRoutePolicy(r)

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
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody(
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

	if !policy.Enabled && !s.deps.Registry().IsModelInCatalog(model) {
		s.deps.Observer.Rejection(dispatch.Rejection{
			Request:         r,
			Stage:           "model_resolution",
			ReasonCode:      "model_not_found",
			HttpStatus:      http.StatusNotFound,
			KeyID:           requestcontext.KeyID(r.Context()),
			ConsumerKeyHash: store.HashKey(requestcontext.AccountID(r.Context())),
			RequestedModel:  publicModel,
			ResolvedModel:   model,
			Params:          rejectionSamplingParams(parsed),
		})
		httpresponse.WriteJSON(w, http.StatusNotFound, httpresponse.ErrorBody("model_not_found",
			fmt.Sprintf("model %q is not available — see /v1/models for supported models", publicModel), httpresponse.WithParam("model")))
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
	if rec, err := s.deps.Store().GetModelRegistryRecord(model); err == nil {
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
	consumerKey := requestcontext.AccountID(r.Context())
	consumerLocation := s.deps.Observer.RequestLocation(r)
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
			s.deps.Settlement().Release(consumerKey, model, reservedMicroUSD, serviceReservation)
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
		if rec, err := s.deps.Store().GetModelRegistryRecord(candidateModel); err == nil {
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
	if rec, err := s.deps.Store().GetModelRegistryRecord(model); err == nil {
		modelMaxContext = rec.MaxContextLength
	}
	s.deps.Observer.DBCall(rp, genericRegistryReadStart)
	rp.Mark(registry.StampReqPlanDone)
	if rp != nil {
		rp.Model, rp.PublicModel, rp.Stream = model, publicModel, stream
		rp.FirstContentBudgetMs = int(genericDeadline.Milliseconds())
		rp.EstimatedPromptTokens, rp.RequestedMaxTokens = estimatedPromptTokens, requestedMaxTokens
		rp.RequiresVision, rp.HasTools = requiresVision, hasTools
		rp.BodyBytes = len(rawBody)
	}
	s.deps.Dispatch().Run(w, r, dispatch.Request{
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
