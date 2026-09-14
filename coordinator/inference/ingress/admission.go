package ingress

import (
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// inferenceAdmissionParams bundles the per-request inputs the shared routing
// preflight needs. model is the resolved build id; the preflight may swap it to
// a Previous build via an alias fallback and returns the final value.
type inferenceAdmissionParams struct {
	model                     string
	publicModel               string
	stream                    bool
	estimatedPromptTokens     int
	requestedMaxTokens        int
	requiresVision            bool
	hasTools                  bool
	traits                    *registry.RequestTraits
	traitsForModel            func(string) registry.RequestTraits
	providerBodyErrorForModel func(string) error
	modelMaxContext           int
	allowedProviderSerials    []string
	deadline                  time.Duration
	policy                    dispatch.RoutePolicy
	// refundReservation releases any pre-flight balance reservation before a
	// terminal rejection. Must be non-nil (a no-op closure on the free paths).
	refundReservation func()
	// onModelFallback refreshes the forward body after an alias fallback rewrote
	// parsed["model"] to a Previous build. It returns ok=false when it wrote a
	// terminal error itself (e.g. the Responses→chat lowering failed), in which
	// case the preflight reports handled=true. Generic paths refresh their
	// lowered body and cache-protocol trait after the alias rewrite.
	onModelFallback func(newModel string) (ok bool)
}

// preflightScanWait is the admission gate's slot-wait budget: a short slice
// (a quarter) of the request's first-content deadline, capped at one second.
// Under saturation admission must shed FAST — a fast 429 relieves CPU — while
// a dispatch attempt may park for its whole remaining budget. Requests
// without a deadline (bare fixtures) get a 250ms slice.
func preflightScanWait(deadline time.Duration) time.Duration {
	wait := deadline / 4
	if wait <= 0 {
		wait = 250 * time.Millisecond
	}
	if wait > time.Second {
		wait = time.Second
	}
	return wait
}

// runInferenceAdmission performs the shared routing/capacity preflight for both
// inference handlers. On a rejection it writes the exact terminal response
// (refunding the reservation) and returns handled=true; on success it returns
// the (possibly fallback-updated) build model and handled=false. Self-route and
// prefer modes short-circuit the public capacity gate exactly as before.
func (s *Controller) runInferenceAdmission(w http.ResponseWriter, r *http.Request, parsed map[string]any, p inferenceAdmissionParams) (string, bool) {
	model := p.model
	publicModel := p.publicModel
	refundReservation := p.refundReservation
	requestTraits := func() registry.RequestTraits {
		if p.traits != nil {
			return *p.traits
		}
		return registry.RequestTraits{HasTools: p.hasTools}
	}
	modelTraits := func(candidateModel string) registry.RequestTraits {
		if p.traitsForModel != nil {
			return p.traitsForModel(candidateModel)
		}
		return requestTraits()
	}
	fallbackTraits := func(currentModel string) registry.RequestTraits {
		target, ok := s.deps.Registry().AliasTarget(publicModel)
		if ok && target.Desired == currentModel && target.Previous != "" {
			return modelTraits(target.Previous)
		}
		return modelTraits(currentModel)
	}
	rejectProviderBodyTooLarge := func(providerBodyErr error) bool {
		if !errors.Is(providerBodyErr, dispatch.ErrProviderBodyTooLarge) {
			return false
		}
		refundReservation()
		s.deps.Observer.Rejection(dispatch.Rejection{
			Request:               r,
			Stage:                 "validation",
			ReasonCode:            "payload_too_large",
			HttpStatus:            http.StatusRequestEntityTooLarge,
			KeyID:                 requestcontext.KeyID(r.Context()),
			ConsumerKeyHash:       store.HashKey(requestcontext.AccountID(r.Context())),
			RequestedModel:        publicModel,
			ResolvedModel:         model,
			Stream:                p.stream,
			EstimatedPromptTokens: p.estimatedPromptTokens,
			RequestedMaxTokens:    p.requestedMaxTokens,
			RequiresVision:        p.requiresVision,
			HasTools:              p.hasTools,
			RequestBodyBytes:      dispatch.OversizedProviderBodyBytes(providerBodyErr),
			Params:                rejectionSamplingParams(parsed),
			ServabilityComputed:   true,
		})
		httpresponse.WriteJSON(w, http.StatusRequestEntityTooLarge, httpresponse.ErrorBody(
			"invalid_request_error", providerBodyErr.Error(),
			httpresponse.WithCode("payload_too_large")))
		return true
	}

	// Gate EVERY preflight fleet walk (self-route/prefer OwnedProviderSummary,
	// the public QuickCapacityCheck family, alias-fallback probes, the
	// servability walk) behind the SAME routing-scan semaphore that bounds the
	// dispatch reservation scans. Without this the 2026-09-01 retry storm
	// still burns unbounded CPU BEFORE the dispatch loop: every admission runs
	// a full fleet walk. The wait is a short slice of the first-content budget
	// — under saturation admission must shed fast, not park for the whole
	// budget the way a dispatch attempt may. The slot is held only for the
	// CPU-bounded walks in this function (released before dispatch/queueing,
	// which take their own slot per reservation; no registry locks are held at
	// acquisition). On timeout: the same capacity-shaped routing_saturated 429
	// with the distress-scaled Retry-After, zero walks. On client-gone: refund
	// and stop silently — never the 429 path or a rejection-ledger row.
	switch s.deps.Dispatch().AcquireRoutingScanSlot(preflightScanWait(p.deadline), r.Context().Done()) {
	case dispatch.ScanSlotClientGone:
		refundReservation()
		return model, true
	case dispatch.ScanSlotTimeout:
		refundReservation()
		retryAfter := s.deps.Dispatch().EstimateRetryAfter(model)
		w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
		s.deps.Metrics.Incr("routing.scan_admission_timeout", []string{"model:" + model, "stage:preflight"})
		s.deps.Metrics.Incr("routing.decisions", []string{"model:" + model, "model_type:" + s.deps.Registry().ModelType(model), "outcome:routing_saturated"})
		s.deps.Observer.Rejection(dispatch.Rejection{
			Request:               r,
			Stage:                 "preflight_capacity",
			ReasonCode:            dispatch.RejectionReasonRoutingSaturated,
			HttpStatus:            http.StatusTooManyRequests,
			KeyID:                 requestcontext.KeyID(r.Context()),
			ConsumerKeyHash:       store.HashKey(requestcontext.AccountID(r.Context())),
			RequestedModel:        publicModel,
			ResolvedModel:         model,
			Stream:                p.stream,
			EstimatedPromptTokens: p.estimatedPromptTokens,
			RequestedMaxTokens:    p.requestedMaxTokens,
			RequiresVision:        p.requiresVision,
			HasTools:              p.hasTools,
			RetryAfterMs:          retryAfter * 1000,
			Params:                rejectionSamplingParams(parsed),
			// Do not add another fleet scan while the scan semaphore is full.
			// recordRejection persists could_have_served=null for this unknown.
			SkipServability: true,
		})
		httpresponse.WriteJSON(w, http.StatusTooManyRequests, httpresponse.ErrorBody("rate_limit_exceeded",
			"the coordinator is at routing capacity — please retry",
			httpresponse.WithCode("rate_limit_exceeded")))
		return model, true
	}
	defer s.deps.Dispatch().ReleaseRoutingScanSlot()

	// Self-route pre-flight: confirm the caller owns an online machine that can
	// serve this model, with precise errors and no fallback to the paid fleet.
	if p.policy.Enabled {
		traits := modelTraits(model)
		if traits.MinPrefixCacheProtocol > 0 && p.providerBodyErrorForModel != nil {
			_, servesWithFloor := s.deps.Registry().OwnedProviderSummary(
				p.policy.OwnerAccountID, model, traits, p.requiresVision)
			withoutProtocolFloor := traits
			withoutProtocolFloor.MinPrefixCacheProtocol = 0
			_, servesWithoutFloor := s.deps.Registry().OwnedProviderSummary(
				p.policy.OwnerAccountID, model, withoutProtocolFloor, p.requiresVision)
			if servesWithFloor == 0 &&
				servesWithoutFloor > 0 &&
				rejectProviderBodyTooLarge(p.providerBodyErrorForModel(model)) {
				return model, true
			}
		}
		if s.selfRouteUnavailable(w, r, p.policy.OwnerAccountID, model, traits, p.requiresVision) {
			refundReservation()
			return model, true
		}
		return model, false
	}
	if p.policy.Prefer {
		traits := modelTraits(model)
		if traits.MinPrefixCacheProtocol > 0 && p.providerBodyErrorForModel != nil {
			_, ownedWithFloor := s.deps.Registry().OwnedProviderSummary(
				p.policy.OwnerAccountID, model, traits, p.requiresVision)
			publicWithFloor, publicCapacityWithFloor, _ :=
				s.deps.Registry().QuickCapacityCheckForRequest(
					model,
					p.estimatedPromptTokens,
					p.requestedMaxTokens,
					traits,
					p.requiresVision,
					p.allowedProviderSerials...,
				)
			withoutProtocolFloor := traits
			withoutProtocolFloor.MinPrefixCacheProtocol = 0
			_, ownedWithoutFloor := s.deps.Registry().OwnedProviderSummary(
				p.policy.OwnerAccountID, model, withoutProtocolFloor, p.requiresVision)
			publicWithoutFloor, publicCapacityWithoutFloor, _ :=
				s.deps.Registry().QuickCapacityCheckForRequest(
					model,
					p.estimatedPromptTokens,
					p.requestedMaxTokens,
					withoutProtocolFloor,
					p.requiresVision,
					p.allowedProviderSerials...,
				)
			hasCompatibleProvider := ownedWithFloor > 0 ||
				publicWithFloor > 0 || publicCapacityWithFloor > 0
			hadProtocolZeroProvider := ownedWithoutFloor > 0 ||
				publicWithoutFloor > 0 || publicCapacityWithoutFloor > 0
			if !hasCompatibleProvider &&
				hadProtocolZeroProvider &&
				rejectProviderBodyTooLarge(p.providerBodyErrorForModel(model)) {
				return model, true
			}
		}
		// Prefer mode: SKIP the public fleet pre-flight. QuickCapacityCheck has
		// no owner-trust relaxation, so it would spuriously 429/503 a request
		// whose own (idle, possibly un-enrolled / private-only) machine could
		// serve it while the public fleet is busy. Dispatch does owned-first
		// routing with a paid public fallback and the normal queue, which is the
		// correct gate for prefer.
		return model, false
	}

	ttftThreshold := p.deadline
	// Pre-flight capacity check: can ANY provider serve this model right
	// now? If not, return 429 immediately rather than queueing for up to
	// 120s. OpenRouter treats 429 as "rate limited" (no uptime penalty) vs
	// 503 which counts as downtime. Fast 429s also preserve our TTFT
	// metrics. Self-route skips this fleet-wide gate — it queues on the
	// owner's machine instead (handled below).
	candidateCount, capacityRejections, modelTooLarge, bestTTFT, hasTTFT := s.deps.Registry().QuickCapacityCheckWithTTFTForRequest(model, p.estimatedPromptTokens, p.requestedMaxTokens, modelTraits(model), p.requiresVision, p.allowedProviderSerials...)
	if candidateCount == 0 && capacityRejections > 0 {
		if fallbackModel, fallbackCandidates, fallbackRejections, fallbackTooLarge, fallbackTTFT, fallbackHasTTFT, switched := s.maybeFallbackAlias(parsed, aliasFallbackCapacity, publicModel, model, p.estimatedPromptTokens, p.requestedMaxTokens, 0, fallbackTraits(model), p.requiresVision, p.allowedProviderSerials); switched {
			model = fallbackModel
			candidateCount, capacityRejections, modelTooLarge = fallbackCandidates, fallbackRejections, fallbackTooLarge
			bestTTFT, hasTTFT = fallbackTTFT, fallbackHasTTFT
			if p.onModelFallback != nil && !p.onModelFallback(model) {
				return model, true
			}
		}
	}
	// Smart early-429 for structurally-unservable long prompts
	// (prompt+max_tokens beyond the model context window or any provider's
	// token budget). Gated (default off) and fail-open. Runs AFTER the alias
	// capacity fallback so an alias whose Previous build still has capacity
	// fails over first; an unservable request is then rejected with an
	// uptime-neutral 429 (OpenRouter fails over) instead of admit→5xx.
	if s.shedIfUnservable(
		w, r, parsed, publicModel, model, p.modelMaxContext, p.stream,
		p.estimatedPromptTokens, p.requestedMaxTokens, p.requiresVision,
		requestTraits(), p.allowedProviderSerials, refundReservation,
	) {
		return model, true
	}
	if candidateCount == 0 && capacityRejections == 0 && modelTooLarge > 0 {
		// Providers serve this model but none can ever fit it — non-retryable.
		// Surface a clear 503 instead of a 429 the client would retry forever.
		refundReservation()
		s.deps.Metrics.Incr("routing.decisions", []string{"model:" + model, "model_type:" + s.deps.Registry().ModelType(model), "outcome:model_too_large"})
		s.deps.Observer.Rejection(dispatch.Rejection{
			Request:                 r,
			Stage:                   "preflight_capacity",
			ReasonCode:              "model_too_large",
			HttpStatus:              http.StatusServiceUnavailable,
			KeyID:                   requestcontext.KeyID(r.Context()),
			ConsumerKeyHash:         store.HashKey(requestcontext.AccountID(r.Context())),
			RequestedModel:          publicModel,
			ResolvedModel:           model,
			Stream:                  p.stream,
			EstimatedPromptTokens:   p.estimatedPromptTokens,
			RequestedMaxTokens:      p.requestedMaxTokens,
			RequiresVision:          p.requiresVision,
			HasTools:                p.hasTools,
			Params:                  rejectionSamplingParams(parsed),
			ServabilityComputed:     true,
			CandidateCount:          candidateCount,
			CapacityRejections:      capacityRejections,
			ModelTooLargeRejections: modelTooLarge,
			BestTTFTMs:              ttftMsForRejection(bestTTFT, hasTTFT),
		})
		httpresponse.WriteJSON(w, http.StatusServiceUnavailable, httpresponse.ErrorBody("model_unavailable",
			fmt.Sprintf("model %q is too large for any currently available provider", publicModel),
			httpresponse.WithCode("model_unavailable")))
		return model, true
	}
	var providerBodyErr error
	if p.providerBodyErrorForModel != nil {
		providerBodyErr = p.providerBodyErrorForModel(model)
	}
	bodyIncompatibilityCausedNoCandidates := false
	if errors.Is(providerBodyErr, dispatch.ErrProviderBodyTooLarge) {
		withoutProtocolFloor := modelTraits(model)
		withoutProtocolFloor.MinPrefixCacheProtocol = 0
		baselineCandidates, baselineCapacity, _ := s.deps.Registry().QuickCapacityCheckForRequest(
			model,
			p.estimatedPromptTokens,
			p.requestedMaxTokens,
			withoutProtocolFloor,
			p.requiresVision,
			p.allowedProviderSerials...,
		)
		bodyIncompatibilityCausedNoCandidates =
			baselineCandidates > 0 || baselineCapacity > 0
	}
	if bodyIncompatibilityCausedNoCandidates &&
		candidateCount == 0 &&
		capacityRejections == 0 &&
		modelTooLarge == 0 {
		if rejectProviderBodyTooLarge(providerBodyErr) {
			return model, true
		}
	}
	if candidateCount == 0 && capacityRejections > 0 {
		// Routing v2 W3: feed the autoscaler the demand the preflight sees.
		s.deps.Registry().RecordWarmPoolCapacityReject(model)
		s.deps.Dispatch().TriggerWarmPool()
		// Queue-before-shed (default on): providers exist for this model but
		// all are at capacity right now. Rather than an immediate 429, let the
		// request fall through to the normal dispatch+queue path so a slot
		// freeing — or a cold load completing — within the queue window serves
		// it. The dispatch/queue path still returns a 429 when the queue is
		// full or the wait times out (true saturation). The reservation is
		// kept for dispatch.
		// Dedicated-family models (e.g. Gemma 4) queue like every other model.
		// They used to fast-429 here (f28e89a9: a TTFT-SLA caution against
		// waiting on a dedicated slot), but the wait is bounded by the queue's
		// maxWait and drains fire fleet-wide on every request completion and
		// heartbeat — across a large dedicated pool a slot frees within
		// seconds, while each fast 429 was an uptime-visible shed to
		// OpenRouter. The drain path (ReserveProviderEx) still applies the
		// dedicated-box routing gate, so a queued request only ever lands on a
		// dedicated provider.
		if s.deps.Dispatch().QueueBeforeShedEnabled() {
			s.deps.Metrics.Incr("routing.decisions", []string{"model:" + model, "model_type:" + s.deps.Registry().ModelType(model), "outcome:capacity_queue_spill"})
		} else {
			// Fast-shed: immediate 429 when queue-before-shed is disabled.
			retryAfter := s.deps.Dispatch().EstimateRetryAfter(model)
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
			refundReservation()
			s.deps.Metrics.Incr("routing.decisions", []string{"model:" + model, "model_type:" + s.deps.Registry().ModelType(model), "outcome:capacity_429"})
			s.deps.Observer.Rejection(dispatch.Rejection{
				Request:                 r,
				Stage:                   "preflight_capacity",
				ReasonCode:              "machine_busy",
				HttpStatus:              http.StatusTooManyRequests,
				KeyID:                   requestcontext.KeyID(r.Context()),
				ConsumerKeyHash:         store.HashKey(requestcontext.AccountID(r.Context())),
				RequestedModel:          publicModel,
				ResolvedModel:           model,
				Stream:                  p.stream,
				EstimatedPromptTokens:   p.estimatedPromptTokens,
				RequestedMaxTokens:      p.requestedMaxTokens,
				RequiresVision:          p.requiresVision,
				HasTools:                p.hasTools,
				RetryAfterMs:            retryAfter * 1000,
				Params:                  rejectionSamplingParams(parsed),
				ServabilityComputed:     true,
				CandidateCount:          candidateCount,
				CapacityRejections:      capacityRejections,
				ModelTooLargeRejections: modelTooLarge,
				BestTTFTMs:              ttftMsForRejection(bestTTFT, hasTTFT),
			})
			httpresponse.WriteJSON(w, http.StatusTooManyRequests, httpresponse.ErrorBody("rate_limit_exceeded",
				fmt.Sprintf("all providers for model %q are at capacity — retry after %ds", publicModel, retryAfter),
				httpresponse.WithCode("rate_limit_exceeded")))
			return model, true
		}
	}
	if candidateCount == 0 && capacityRejections == 0 && modelTooLarge == 0 {
		// No provider is even structurally eligible right now: the model's
		// whole pool is offline/untrusted, trait-gated (below the tools floor
		// / render-broken), or — the case the shape-keyed breaker introduces —
		// every serving provider is in inference-error cooldown for THIS
		// request shape.
		//
		// Routing v2 W3 cold-dispatch (default on): before shedding, check
		// whether an idle on-disk provider could be WARMED to serve this model
		// (and would then pass admission for these traits). If so, spill the
		// request into the queue instead of 503'ing — the enqueue path kicks
		// the model-swap machinery, and the queued request drains onto the
		// provider once the cold load completes. Note that an idle, fitting
		// cold provider is already a scheduler candidate (slot "unknown" is
		// eligible), so this branch usually only fires for genuinely
		// unservable demand; it is the safety valve for the narrow window
		// where a loadable cold provider is not yet a candidate.
		//
		// Feed the autoscaler the demand regardless of outcome.
		s.deps.Registry().RecordWarmPoolCapacityReject(model)
		s.deps.Dispatch().TriggerWarmPool()
		if s.deps.Dispatch().ColdDispatchEnabled() && s.deps.Dispatch().ColdSpillAvailable(model, modelTraits(model), p.requiresVision, p.allowedProviderSerials) {
			s.deps.Metrics.Incr("routing.decisions", []string{"model:" + model, "model_type:" + s.deps.Registry().ModelType(model), "outcome:cold_dispatch_spill"})
			// Fall through to dispatch+queue; reservation kept.
		} else if s.deps.Registry().IsDedicatedModel(model) && s.deps.Registry().HasProviderForModel(model, p.allowedProviderSerials...) {
			// Dedicated-box model (e.g. Gemma 4): the fleet DOES serve this
			// model, but no provider DEDICATED to it can take the request right
			// now — either none are dedicated, or the dedicated ones are busy/
			// cooling. That is transient capacity pressure, not an absent model,
			// so shed to OpenRouter as a 429 + Retry-After (clean failover)
			// rather than a 503 (which can get the endpoint marked unhealthy /
			// deranked). Mirrors the capacity_429 path above.
			retryAfter := s.deps.Dispatch().EstimateRetryAfter(model)
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
			refundReservation()
			s.deps.Metrics.Incr("routing.decisions", []string{"model:" + model, "model_type:" + s.deps.Registry().ModelType(model), "outcome:dedicated_capacity_429"})
			s.deps.Observer.Rejection(dispatch.Rejection{
				Request:                 r,
				Stage:                   "preflight_capacity",
				ReasonCode:              "machine_busy",
				HttpStatus:              http.StatusTooManyRequests,
				KeyID:                   requestcontext.KeyID(r.Context()),
				ConsumerKeyHash:         store.HashKey(requestcontext.AccountID(r.Context())),
				RequestedModel:          publicModel,
				ResolvedModel:           model,
				Stream:                  p.stream,
				EstimatedPromptTokens:   p.estimatedPromptTokens,
				RequestedMaxTokens:      p.requestedMaxTokens,
				RequiresVision:          p.requiresVision,
				HasTools:                p.hasTools,
				RetryAfterMs:            retryAfter * 1000,
				Params:                  rejectionSamplingParams(parsed),
				ServabilityComputed:     true,
				CandidateCount:          candidateCount,
				CapacityRejections:      capacityRejections,
				ModelTooLargeRejections: modelTooLarge,
				BestTTFTMs:              ttftMsForRejection(bestTTFT, hasTTFT),
			})
			httpresponse.WriteJSON(w, http.StatusTooManyRequests, httpresponse.ErrorBody("rate_limit_exceeded",
				fmt.Sprintf("no provider dedicated to model %q is available right now — retry after %ds", publicModel, retryAfter),
				httpresponse.WithCode("rate_limit_exceeded")))
			return model, true
		} else {
			// The catalog still sells this model, but no provider is eligible
			// right now: the fleet may be reconnecting after a coordinator
			// restart, temporarily untrusted, or in a shape-specific cooldown.
			// This is transient capacity exhaustion. Fail fast with 429 +
			// Retry-After so upstream routers can try another endpoint without
			// counting the event as a provider outage. A 503 here caused the
			// post-deploy OpenRouter uptime collapse while the in-memory
			// provider registry repopulated.
			retryAfter := s.deps.Dispatch().EstimateRetryAfter(model)
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
			refundReservation()
			s.deps.Metrics.Incr("routing.decisions", []string{"model:" + model, "model_type:" + s.deps.Registry().ModelType(model), "outcome:no_eligible_provider"})
			s.deps.Observer.Rejection(dispatch.Rejection{
				Request:                 r,
				Stage:                   "preflight_capacity",
				ReasonCode:              "no_provider",
				HttpStatus:              http.StatusTooManyRequests,
				KeyID:                   requestcontext.KeyID(r.Context()),
				ConsumerKeyHash:         store.HashKey(requestcontext.AccountID(r.Context())),
				RequestedModel:          publicModel,
				ResolvedModel:           model,
				Stream:                  p.stream,
				EstimatedPromptTokens:   p.estimatedPromptTokens,
				RequestedMaxTokens:      p.requestedMaxTokens,
				RequiresVision:          p.requiresVision,
				HasTools:                p.hasTools,
				RetryAfterMs:            retryAfter * 1000,
				Params:                  rejectionSamplingParams(parsed),
				ServabilityComputed:     true,
				CandidateCount:          candidateCount,
				CapacityRejections:      capacityRejections,
				ModelTooLargeRejections: modelTooLarge,
				BestTTFTMs:              ttftMsForRejection(bestTTFT, hasTTFT),
			})
			httpresponse.WriteJSON(w, http.StatusTooManyRequests, httpresponse.ErrorBody("rate_limit_exceeded",
				fmt.Sprintf("no provider for model %q is available right now — retry after %ds", publicModel, retryAfter),
				httpresponse.WithCode("rate_limit_exceeded")))
			return model, true
		}
	}
	if ttftTooSlow(bestTTFT, hasTTFT, ttftThreshold) {
		if !s.deps.Dispatch().HardTTFTGateApplies(p.requiresVision) {
			// Soft TTFT path: either global hard rejection is disabled (the
			// default), or this is media whose decode+tower costs are absent
			// from the token-prefill estimate. pr.MaxTTFTMs stays 0, so dispatch
			// serves the best available provider while the request-absolute
			// first-content clock remains authoritative. Do not divert a
			// routable desired build to an older alias.
			// Keep the text soft-gate pressure signal, but do not teach the warm
			// pool from a media projection that omits decode and tower work.
			if !p.requiresVision {
				s.deps.Registry().RecordWarmPoolTTFTMiss(model, ttftThreshold)
				s.deps.Dispatch().TriggerWarmPool()
			}
			s.deps.Metrics.Incr("routing.decisions", []string{"model:" + model, "model_type:" + s.deps.Registry().ModelType(model), "outcome:ttft_soft_served"})
		} else if fallbackModel, _, _, _, fallbackTTFT, fallbackHasTTFT, switched := s.maybeFallbackAlias(parsed, aliasFallbackTTFT, publicModel, model, p.estimatedPromptTokens, p.requestedMaxTokens, ttftThreshold, fallbackTraits(model), p.requiresVision, p.allowedProviderSerials); switched {
			model = fallbackModel
			if p.onModelFallback != nil && !p.onModelFallback(model) {
				return model, true
			}
		} else {
			// Hard TTFT gate, no faster alias: shed with a 429 + Retry-After,
			// and feed the autoscaler a TTFT-miss so warm capacity grows.
			s.deps.Registry().RecordWarmPoolTTFTMiss(model, ttftThreshold)
			s.deps.Dispatch().TriggerWarmPool()
			retryModel, retryTTFT := fasterTTFTEstimate(model, bestTTFT, fallbackModel, fallbackTTFT, fallbackHasTTFT)
			refundReservation()
			s.deps.Observer.Rejection(dispatch.Rejection{
				Request:                 r,
				Stage:                   "routing_ttft",
				ReasonCode:              "ttft_too_slow",
				HttpStatus:              http.StatusTooManyRequests,
				KeyID:                   requestcontext.KeyID(r.Context()),
				ConsumerKeyHash:         store.HashKey(requestcontext.AccountID(r.Context())),
				RequestedModel:          publicModel,
				ResolvedModel:           model,
				Stream:                  p.stream,
				EstimatedPromptTokens:   p.estimatedPromptTokens,
				RequestedMaxTokens:      p.requestedMaxTokens,
				RequiresVision:          p.requiresVision,
				HasTools:                p.hasTools,
				Params:                  rejectionSamplingParams(parsed),
				ServabilityComputed:     true,
				CandidateCount:          candidateCount,
				CapacityRejections:      capacityRejections,
				ModelTooLargeRejections: modelTooLarge,
				BestTTFTMs:              float64(retryTTFT.Milliseconds()),
			})
			s.deps.Dispatch().WriteTTFTTooSlow(w, retryModel, publicModel, retryTTFT, ttftThreshold)
			return model, true
		}
	}
	return model, false
}
