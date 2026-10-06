package inference

import (
	"errors"
	"fmt"
	"net/http"
	"strconv"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/providerwire"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Run performs the shared routing/capacity preflight for both
// inference handlers. On a rejection it writes the exact terminal response
// (refunding the reservation) and returns handled=true; on success it returns
// the (possibly fallback-updated) build model and handled=false. Self-route and
// prefer modes short-circuit the public capacity gate exactly as before.
func (a *Admission) Run(w http.ResponseWriter, r *http.Request, parsed map[string]any, p AdmissionRequest) AdmissionResult {
	s := a.owner
	markPublicModelDemand(r, p)
	model := p.Model
	armAutopilotDemand(r, p)
	defer func() { setAutopilotDemandModel(r, model, p.requestTraitsForModel(model)) }()
	publicModel := p.PublicModel
	refundReservation := p.RefundReservation
	requestTraits := func() registry.RequestTraits {
		if p.Traits != nil {
			return *p.Traits
		}
		return registry.RequestTraits{HasTools: p.HasTools}
	}
	modelTraits := func(candidateModel string) registry.RequestTraits {
		return p.requestTraitsForModel(candidateModel)
	}
	fallbackTraits := func(currentModel string) registry.RequestTraits {
		target, ok := s.registry.AliasTarget(publicModel)
		if ok && target.Desired == currentModel && target.Previous != "" {
			return modelTraits(target.Previous)
		}
		return modelTraits(currentModel)
	}
	rejectProviderBodyTooLarge := func(providerBodyErr error) bool {
		if !errors.Is(providerBodyErr, providerwire.ErrBodyTooLarge) {
			return false
		}
		refundReservation()
		s.recordRejection(rejectionInfo{
			r:                     r,
			stage:                 "validation",
			reasonCode:            "payload_too_large",
			httpStatus:            http.StatusRequestEntityTooLarge,
			keyID:                 access.KeyIDFromContext(r.Context()),
			consumerKeyHash:       store.HashKey(access.ConsumerKeyFromContext(r.Context())),
			requestedModel:        publicModel,
			resolvedModel:         model,
			stream:                p.Stream,
			estimatedPromptTokens: p.EstimatedPromptTokens,
			requestedMaxTokens:    p.RequestedMaxTokens,
			requiresVision:        p.RequiresVision,
			hasTools:              p.HasTools,
			requestBodyBytes:      providerwire.OversizedBodyBytes(providerBodyErr),
			params:                rejectionSamplingParams(parsed),
			servabilityComputed:   true,
		})
		httpx.WriteJSON(w, http.StatusRequestEntityTooLarge, httpx.ErrorResponse(
			"invalid_request_error", providerBodyErr.Error(), httpx.WithCode("payload_too_large")))
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
	permit := admissionScanPermit{admission: a, w: w, r: r, parsed: parsed, params: p}
	if !permit.acquire(model) {
		return AdmissionResult{Model: model, Handled: true}
	}
	defer permit.release()

	// Self-route pre-flight: confirm the caller owns an online machine that can
	// serve this model, with precise errors and no fallback to the paid fleet.
	if p.Policy.Enabled {
		traits := modelTraits(model)
		if traits.MinPrefixCacheProtocol > 0 && p.ProviderBodyErrorForModel != nil {
			_, servesWithFloor := s.registry.OwnedProviderSummary(
				p.Policy.OwnerAccountID, model, traits, p.RequiresVision)
			withoutProtocolFloor := traits
			withoutProtocolFloor.MinPrefixCacheProtocol = 0
			_, servesWithoutFloor := s.registry.OwnedProviderSummary(
				p.Policy.OwnerAccountID, model, withoutProtocolFloor, p.RequiresVision)
			if servesWithFloor == 0 &&
				servesWithoutFloor > 0 &&
				rejectProviderBodyTooLarge(p.ProviderBodyErrorForModel(model)) {
				return AdmissionResult{Model: model, Handled: true}
			}
		}
		if s.selfRouteUnavailable(w, r, p.Policy.OwnerAccountID, model, traits, p.RequiresVision) {
			refundReservation()
			return AdmissionResult{Model: model, Handled: true}
		}
		return AdmissionResult{Model: model}
	}
	if p.Policy.Prefer {
		traits := modelTraits(model)
		if traits.MinPrefixCacheProtocol > 0 && p.ProviderBodyErrorForModel != nil {
			_, ownedWithFloor := s.registry.OwnedProviderSummary(
				p.Policy.OwnerAccountID, model, traits, p.RequiresVision)
			publicWithFloor, publicCapacityWithFloor, _ :=
				s.registry.QuickCapacityCheckForRequest(
					model,
					p.EstimatedPromptTokens,
					p.RequestedMaxTokens,
					traits,
					p.RequiresVision,
					p.AllowedProviderSerials...,
				)
			withoutProtocolFloor := traits
			withoutProtocolFloor.MinPrefixCacheProtocol = 0
			_, ownedWithoutFloor := s.registry.OwnedProviderSummary(
				p.Policy.OwnerAccountID, model, withoutProtocolFloor, p.RequiresVision)
			publicWithoutFloor, publicCapacityWithoutFloor, _ :=
				s.registry.QuickCapacityCheckForRequest(
					model,
					p.EstimatedPromptTokens,
					p.RequestedMaxTokens,
					withoutProtocolFloor,
					p.RequiresVision,
					p.AllowedProviderSerials...,
				)
			hasCompatibleProvider := ownedWithFloor > 0 ||
				publicWithFloor > 0 || publicCapacityWithFloor > 0
			hadProtocolZeroProvider := ownedWithoutFloor > 0 ||
				publicWithoutFloor > 0 || publicCapacityWithoutFloor > 0
			if !hasCompatibleProvider &&
				hadProtocolZeroProvider &&
				rejectProviderBodyTooLarge(p.ProviderBodyErrorForModel(model)) {
				return AdmissionResult{Model: model, Handled: true}
			}
		}
		// Prefer mode: SKIP the public fleet pre-flight. QuickCapacityCheck has
		// no owner-trust relaxation, so it would spuriously 429/503 a request
		// whose own (idle, possibly un-enrolled / private-only) machine could
		// serve it while the public fleet is busy. Dispatch does owned-first
		// routing with a paid public fallback and the normal queue, which is the
		// correct gate for prefer.
		return AdmissionResult{Model: model}
	}

	// Pre-flight capacity check: can ANY provider serve this model right
	// now? If not, return 429 immediately rather than queueing for up to
	// 120s. OpenRouter treats 429 as "rate limited" (no uptime penalty) vs
	// 503 which counts as downtime. Fast 429s also preserve our TTFT
	// metrics. Self-route skips this fleet-wide gate — it queues on the
	// owner's machine instead (handled below).
	forecastRequest := func(candidateModel string) *registry.PendingRequest {
		// Exact cache planning may call the prompt-contract sidecar. It must
		// not occupy a CPU scan permit, including on a lazy alias fallback.
		permit.release()
		query := p.firstContentRequest(candidateModel, modelTraits(candidateModel))
		query.MinDecodeTPS = s.minDecodeTPS
		if !permit.acquire(candidateModel) {
			return nil
		}
		return query
	}
	forecast := forecastRequest(model)
	if forecast == nil {
		return AdmissionResult{Model: model, Handled: true}
	}
	candidateCount, capacityRejections, modelTooLarge, bestTTFT, hasTTFT := s.registry.QuickFirstContentCapacityForRequest(model, forecast)
	if candidateCount == 0 && capacityRejections > 0 {
		fallbackModel, fallbackCandidates, fallbackRejections, fallbackTooLarge, fallbackTTFT, fallbackHasTTFT, switched := s.maybeFallbackAlias(parsed, aliasFallbackCapacity, publicModel, model, p.EstimatedPromptTokens, p.RequestedMaxTokens, 0, fallbackTraits(model), p.RequiresVision, p.AllowedProviderSerials, forecastRequest)
		if !permit.held {
			return AdmissionResult{Model: model, Handled: true}
		}
		if switched {
			model = fallbackModel
			candidateCount, capacityRejections, modelTooLarge = fallbackCandidates, fallbackRejections, fallbackTooLarge
			bestTTFT, hasTTFT = fallbackTTFT, fallbackHasTTFT
			if p.OnModelFallback != nil {
				permit.release()
				if !p.OnModelFallback(model) || !permit.acquire(model) {
					return AdmissionResult{Model: model, Handled: true}
				}
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
		w, r, parsed, publicModel, model, p.ModelMaxContext, p.Stream,
		p.EstimatedPromptTokens, p.RequestedMaxTokens, p.RequiresVision,
		requestTraits(), p.AllowedProviderSerials, refundReservation,
	) {
		return AdmissionResult{Model: model, Handled: true}
	}
	if candidateCount == 0 && capacityRejections == 0 && modelTooLarge > 0 {
		// Providers serve this model but none can ever fit it — non-retryable.
		// Surface a clear 503 instead of a 429 the client would retry forever.
		refundReservation()
		s.observation.Incr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:model_too_large"})
		s.recordRejection(rejectionInfo{
			r:                       r,
			stage:                   "preflight_capacity",
			reasonCode:              "model_too_large",
			httpStatus:              http.StatusServiceUnavailable,
			keyID:                   access.KeyIDFromContext(r.Context()),
			consumerKeyHash:         store.HashKey(access.ConsumerKeyFromContext(r.Context())),
			requestedModel:          publicModel,
			resolvedModel:           model,
			stream:                  p.Stream,
			estimatedPromptTokens:   p.EstimatedPromptTokens,
			requestedMaxTokens:      p.RequestedMaxTokens,
			requiresVision:          p.RequiresVision,
			hasTools:                p.HasTools,
			params:                  rejectionSamplingParams(parsed),
			servabilityComputed:     true,
			candidateCount:          candidateCount,
			capacityRejections:      capacityRejections,
			modelTooLargeRejections: modelTooLarge,
			bestTTFTMs:              ttftMsForRejection(bestTTFT, hasTTFT),
		})
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("model_unavailable",
			fmt.Sprintf("model %q is too large for any currently available provider", publicModel), httpx.WithCode("model_unavailable")))
		return AdmissionResult{Model: model, Handled: true}
	}
	var providerBodyErr error
	if p.ProviderBodyErrorForModel != nil {
		providerBodyErr = p.ProviderBodyErrorForModel(model)
	}
	bodyIncompatibilityCausedNoCandidates := false
	if errors.Is(providerBodyErr, providerwire.ErrBodyTooLarge) {
		withoutProtocolFloor := modelTraits(model)
		withoutProtocolFloor.MinPrefixCacheProtocol = 0
		baselineCandidates, baselineCapacity, _ := s.registry.QuickCapacityCheckForRequest(
			model,
			p.EstimatedPromptTokens,
			p.RequestedMaxTokens,
			withoutProtocolFloor,
			p.RequiresVision,
			p.AllowedProviderSerials...,
		)
		bodyIncompatibilityCausedNoCandidates =
			baselineCandidates > 0 || baselineCapacity > 0
	}
	if bodyIncompatibilityCausedNoCandidates &&
		candidateCount == 0 &&
		capacityRejections == 0 &&
		modelTooLarge == 0 {
		if rejectProviderBodyTooLarge(providerBodyErr) {
			return AdmissionResult{Model: model, Handled: true}
		}
	}
	if candidateCount == 0 && capacityRejections > 0 {
		// Routing v2 W3: feed the autoscaler the demand the preflight sees.
		s.registry.RecordWarmPoolCapacityReject(model)
		s.triggerWarmPool()
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
		if s.queueBeforeShedEnabled() {
			s.observation.Incr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:capacity_queue_spill"})
		} else {
			// Fast-shed: immediate 429 when queue-before-shed is disabled.
			retryAfter := s.estimateRetryAfter(model)
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
			refundReservation()
			s.observation.Incr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:capacity_429"})
			s.recordRejection(rejectionInfo{
				r:                       r,
				stage:                   "preflight_capacity",
				reasonCode:              "machine_busy",
				httpStatus:              http.StatusTooManyRequests,
				keyID:                   access.KeyIDFromContext(r.Context()),
				consumerKeyHash:         store.HashKey(access.ConsumerKeyFromContext(r.Context())),
				requestedModel:          publicModel,
				resolvedModel:           model,
				stream:                  p.Stream,
				estimatedPromptTokens:   p.EstimatedPromptTokens,
				requestedMaxTokens:      p.RequestedMaxTokens,
				requiresVision:          p.RequiresVision,
				hasTools:                p.HasTools,
				retryAfterMs:            retryAfter * 1000,
				params:                  rejectionSamplingParams(parsed),
				servabilityComputed:     true,
				candidateCount:          candidateCount,
				capacityRejections:      capacityRejections,
				modelTooLargeRejections: modelTooLarge,
				bestTTFTMs:              ttftMsForRejection(bestTTFT, hasTTFT),
			})
			httpx.WriteJSON(w, http.StatusTooManyRequests, httpx.ErrorResponse("rate_limit_exceeded",
				fmt.Sprintf("all providers for model %q are at capacity — retry after %ds", publicModel, retryAfter), httpx.WithCode("rate_limit_exceeded")))
			return AdmissionResult{Model: model, Handled: true}
		}
	}
	if candidateCount == 0 && capacityRejections == 0 && modelTooLarge == 0 {
		// No provider is even structurally eligible right now: the model's
		// whole pool is offline/untrusted, trait-gated (e.g. render-broken),
		// or — the case the shape-keyed breaker introduces —
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
		s.registry.RecordWarmPoolCapacityReject(model)
		s.triggerWarmPool()
		if s.coldDispatchEnabled() && s.coldSpillAvailable(model, modelTraits(model), p.RequiresVision, p.AllowedProviderSerials) {
			s.observation.Incr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:cold_dispatch_spill"})
			// Fall through to dispatch+queue; reservation kept.
		} else if s.registry.IsDedicatedModel(model) && s.registry.HasProviderForModel(model, p.AllowedProviderSerials...) {
			// Dedicated-box model (e.g. Gemma 4): the fleet DOES serve this
			// model, but no provider DEDICATED to it can take the request right
			// now — either none are dedicated, or the dedicated ones are busy/
			// cooling. That is transient capacity pressure, not an absent model,
			// so shed to OpenRouter as a 429 + Retry-After (clean failover)
			// rather than a 503 (which can get the endpoint marked unhealthy /
			// deranked). Mirrors the capacity_429 path above.
			retryAfter := s.estimateRetryAfter(model)
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
			refundReservation()
			s.observation.Incr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:dedicated_capacity_429"})
			s.recordRejection(rejectionInfo{
				r:                       r,
				stage:                   "preflight_capacity",
				reasonCode:              "machine_busy",
				httpStatus:              http.StatusTooManyRequests,
				keyID:                   access.KeyIDFromContext(r.Context()),
				consumerKeyHash:         store.HashKey(access.ConsumerKeyFromContext(r.Context())),
				requestedModel:          publicModel,
				resolvedModel:           model,
				stream:                  p.Stream,
				estimatedPromptTokens:   p.EstimatedPromptTokens,
				requestedMaxTokens:      p.RequestedMaxTokens,
				requiresVision:          p.RequiresVision,
				hasTools:                p.HasTools,
				retryAfterMs:            retryAfter * 1000,
				params:                  rejectionSamplingParams(parsed),
				servabilityComputed:     true,
				candidateCount:          candidateCount,
				capacityRejections:      capacityRejections,
				modelTooLargeRejections: modelTooLarge,
				bestTTFTMs:              ttftMsForRejection(bestTTFT, hasTTFT),
			})
			httpx.WriteJSON(w, http.StatusTooManyRequests, httpx.ErrorResponse("rate_limit_exceeded",
				fmt.Sprintf("no provider dedicated to model %q is available right now — retry after %ds", publicModel, retryAfter), httpx.WithCode("rate_limit_exceeded")))
			return AdmissionResult{Model: model, Handled: true}
		} else {
			// The catalog still sells this model, but no provider is eligible
			// right now: the fleet may be reconnecting after a coordinator
			// restart, temporarily untrusted, or in a shape-specific cooldown.
			// This is transient capacity exhaustion. Fail fast with 429 +
			// Retry-After so upstream routers can try another endpoint without
			// counting the event as a provider outage. A 503 here caused the
			// post-deploy OpenRouter uptime collapse while the in-memory
			// provider registry repopulated.
			retryAfter := s.estimateRetryAfter(model)
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
			refundReservation()
			s.observation.Incr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:no_eligible_provider"})
			s.recordRejection(rejectionInfo{
				r:                       r,
				stage:                   "preflight_capacity",
				reasonCode:              "no_provider",
				httpStatus:              http.StatusTooManyRequests,
				keyID:                   access.KeyIDFromContext(r.Context()),
				consumerKeyHash:         store.HashKey(access.ConsumerKeyFromContext(r.Context())),
				requestedModel:          publicModel,
				resolvedModel:           model,
				stream:                  p.Stream,
				estimatedPromptTokens:   p.EstimatedPromptTokens,
				requestedMaxTokens:      p.RequestedMaxTokens,
				requiresVision:          p.RequiresVision,
				hasTools:                p.HasTools,
				retryAfterMs:            retryAfter * 1000,
				params:                  rejectionSamplingParams(parsed),
				servabilityComputed:     true,
				candidateCount:          candidateCount,
				capacityRejections:      capacityRejections,
				modelTooLargeRejections: modelTooLarge,
				bestTTFTMs:              ttftMsForRejection(bestTTFT, hasTTFT),
			})
			httpx.WriteJSON(w, http.StatusTooManyRequests, httpx.ErrorResponse("rate_limit_exceeded",
				fmt.Sprintf("no provider for model %q is available right now — retry after %ds", publicModel, retryAfter), httpx.WithCode("rate_limit_exceeded")))
			return AdmissionResult{Model: model, Handled: true}
		}
	}
	ttftThreshold := p.remainingFirstContentBudget()
	if ttftTooSlow(bestTTFT, hasTTFT, ttftThreshold) {
		if !s.hardTTFTGateApplies(p.RequiresVision) {
			// Soft TTFT path: either global hard rejection is disabled (the
			// default), or this is media whose decode+tower costs are absent
			// from the token-prefill estimate. pr.MaxTTFTMs stays 0, so dispatch
			// serves the best available provider while the request-absolute
			// first-content clock remains authoritative. Do not divert a
			// routable desired build to an older alias.
			// Keep the text soft-gate pressure signal, but do not teach the warm
			// pool from a media projection that omits decode and tower work.
			if !p.RequiresVision {
				s.registry.RecordWarmPoolTTFTMiss(model, ttftThreshold)
				s.triggerWarmPool()
			}
			s.observation.Incr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:ttft_soft_served"})
		} else if fallbackModel, _, _, _, fallbackTTFT, fallbackHasTTFT, switched := s.maybeFallbackAlias(parsed, aliasFallbackTTFT, publicModel, model, p.EstimatedPromptTokens, p.RequestedMaxTokens, ttftThreshold, fallbackTraits(model), p.RequiresVision, p.AllowedProviderSerials, forecastRequest); switched {
			model = fallbackModel
			if p.OnModelFallback != nil {
				permit.release()
				if !p.OnModelFallback(model) {
					return AdmissionResult{Model: model, Handled: true}
				}
			}
		} else {
			if !permit.held {
				return AdmissionResult{Model: model, Handled: true}
			}
			// Hard TTFT gate, no faster alias: shed with a 429 + Retry-After,
			// and feed the autoscaler a TTFT-miss so warm capacity grows.
			s.registry.RecordWarmPoolTTFTMiss(model, ttftThreshold)
			s.triggerWarmPool()
			retryModel, retryTTFT := fasterTTFTEstimate(model, bestTTFT, fallbackModel, fallbackTTFT, fallbackHasTTFT)
			refundReservation()
			s.recordRejection(rejectionInfo{
				r:                       r,
				stage:                   "routing_ttft",
				reasonCode:              "ttft_too_slow",
				httpStatus:              http.StatusTooManyRequests,
				keyID:                   access.KeyIDFromContext(r.Context()),
				consumerKeyHash:         store.HashKey(access.ConsumerKeyFromContext(r.Context())),
				requestedModel:          publicModel,
				resolvedModel:           model,
				stream:                  p.Stream,
				estimatedPromptTokens:   p.EstimatedPromptTokens,
				requestedMaxTokens:      p.RequestedMaxTokens,
				requiresVision:          p.RequiresVision,
				hasTools:                p.HasTools,
				params:                  rejectionSamplingParams(parsed),
				servabilityComputed:     true,
				candidateCount:          candidateCount,
				capacityRejections:      capacityRejections,
				modelTooLargeRejections: modelTooLarge,
				bestTTFTMs:              float64(retryTTFT.Milliseconds()),
			})
			s.writeTTFTTooSlow(w, retryModel, publicModel, retryTTFT, ttftThreshold)
			return AdmissionResult{Model: model, Handled: true}
		}
	}
	return AdmissionResult{Model: model}
}
