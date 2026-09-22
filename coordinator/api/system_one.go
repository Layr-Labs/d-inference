package api

import (
	"fmt"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// handleSystemOne shares authenticated transport, billing, admission, encrypted
// dispatch, failover and cancellation with generation, but owns native request
// and response semantics. No chat template, KV cache or output allocation is
// introduced for an encoder decision.
func (s *Server) handleSystemOne(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, maxSystemOneBodyBytes)
	r = withModelTokenRequest(r)
	timing := &registry.RequestTiming{ReceivedAt: time.Now()}
	profile := s.newRequestProfile(r, "", "", false)
	prelude, ok := s.parseInferencePrelude(w, r)
	if !ok {
		return
	}
	questionCount, err := validateSystemOneRequest(prelude.parsed)
	if err != nil {
		writeJSON(w, http.StatusUnprocessableEntity, errorResponse("invalid_request_error", err.Error()))
		return
	}
	parsed := prelude.parsed
	policy := s.resolveSelfRoutePolicy(r)
	traits := registry.RequestTraits{SystemOne: true}
	model, publicModel, _, ok := s.resolveRequestedBuild(parsed, prelude.model, nil, policy, traits)
	if !ok {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_unavailable", "no compatible SystemOne build is available", withParam("model")))
		return
	}
	if !policy.enabled && !s.registry.IsModelInCatalog(model) {
		writeJSON(w, http.StatusNotFound, errorResponse("model_not_found", "model is not available", withParam("model")))
		return
	}
	if !s.registry.IsSystemOneModel(model) && !policy.enabled {
		writeJSON(w, http.StatusUnprocessableEntity, errorResponse("model_capability", fmt.Sprintf("model %q does not support SystemOne", publicModel), withParam("model")))
		return
	}
	if !s.registry.HasSystemOneProviderForRouting(model, policy.ownerAccountID, policy.enabled, policy.prefer) {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_unavailable", "no provider supports native SystemOne inference for this model"))
		return
	}
	// Every question is one encoder row of at most 512 tokens. Reserving that
	// exact upper bound also accounts for repeated state across questions.
	promptBound := questionCount * systemOneTokensPerQuestion
	deadline, err := s.requestFirstContentDeadline(r, publicModel, model, promptBound)
	if err != nil {
		s.writeServiceUnavailable(w, model)
		return
	}
	timing.ParsedAt = time.Now()
	profile.Mark(registry.StampReqParsed)
	if s.shedIfModelRejected(w, r, parsed, policy, publicModel, model, false, promptBound, 0, false, false) {
		return
	}
	tokenAdmission, ok := s.applyTokenRateLimitWithAdmission(w, r, promptBound, 0)
	if !ok {
		return
	}
	reserved, serviceReservation, handled := s.reserveInferenceBalance(w, r, parsed, balanceReservationParams{
		model: model, publicModel: publicModel,
		billingPromptTokens: promptBound, estimatedPromptTokens: promptBound,
		requestedMaxTokens: 0, policy: policy,
	})
	if handled {
		return
	}
	consumerKey := consumerKeyFromContext(r.Context())
	refund := func() {
		if s.releaseModelTokenRequest(r) {
			return
		}
		if reserved > 0 {
			s.releaseInitialReservation(consumerKey, model, reserved, serviceReservation)
		}
	}
	timing.ReservedAt = time.Now()
	profile.Mark(registry.StampReqReserved)
	var body []byte
	bodyForModel := func(candidate string) ([]byte, error) {
		body, err := systemOneProviderBody(prelude.originalRawBody, candidate)
		if err != nil {
			return nil, err
		}
		if len(body) > maxSystemOneBodyBytes {
			return nil, fmt.Errorf("native request exceeds %d-byte limit", maxSystemOneBodyBytes)
		}
		_, err = routingTraitsForProviderBody(false, body, false)
		return body, err
	}
	refresh := func(candidate string) bool {
		var err error
		body, err = bodyForModel(candidate)
		if err != nil {
			writeJSON(w, http.StatusRequestEntityTooLarge, errorResponse("invalid_request_error", "native request exceeds provider body limit"))
			refund()
			return false
		}
		return true
	}
	if !refresh(model) {
		return
	}
	model, handled = s.runInferenceAdmission(w, r, parsed, inferenceAdmissionParams{
		model: model, publicModel: publicModel,
		estimatedPromptTokens: promptBound, requestedMaxTokens: 0,
		traits: &traits, traitsForModel: func(string) registry.RequestTraits { return traits },
		providerBodyErrorForModel: func(candidate string) error { _, err := bodyForModel(candidate); return err },
		// The catalog context is per question, not the sum of independent rows.
		modelMaxContext: 0, deadline: deadline, policy: policy,
		refundReservation: refund, onModelFallback: refresh,
	})
	profile.Mark(registry.StampReqPreflightDone)
	if handled {
		return
	}
	profile.Mark(registry.StampReqPlanDone)
	if profile != nil {
		profile.Model, profile.PublicModel = model, publicModel
		profile.EstimatedPromptTokens = promptBound
		profile.BodyBytes = len(body)
		profile.FirstContentBudgetMs = int(deadline.Milliseconds())
	}
	d := &dispatchState{
		s: s, w: w, r: r, model: model, publicModel: publicModel, rawBody: body,
		consumerKey: consumerKey, consumerLocation: s.requestLocation(r),
		reservedMicroUSD: reserved, serviceReservation: serviceReservation,
		estimatedPromptTokens: promptBound, requestedMaxTokens: 0,
		tokenAdmission: tokenAdmission, systemOne: true, consumerEndpoint: systemOneEndpoint,
		systemOneQuestions: systemOneQuestionContract(parsed),
		policy:             policy, timing: timing, profile: profile, deadline: deadline,
		speculativeAt:     s.firstContentHedgeDelay(model, promptBound, deadline),
		refundReservation: refund, excludeProviders: make(map[string]struct{}),
	}
	d.run()
}
