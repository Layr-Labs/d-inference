package api

// Shared routing/capacity admission preflight for the consumer inference
// handlers.
//
// handleChatCompletions and handleGenericInference (completions + Anthropic
// messages) carried byte-identical copies of the self-route / prefer / public
// capacity-and-TTFT preflight: ~280 lines of QuickCapacityCheck → alias-capacity
// fallback → unservable shed → model-too-large → capacity 429 / queue-spill →
// no-eligible-provider shed → TTFT gate, each writing the exact same
// OpenAI-compatible rejections and routing.decisions metrics. The ONLY
// divergence (verified by diffing the two blocks) is the forward-body refresh
// after an alias fallback rewrites parsed["model"]: chat re-marshals its threaded
// rawBody (and, for the Responses API, re-lowers input→chat, which can itself
// fail with a 400), while the generic path rebuilds the body from parsed at
// dispatch time and needs no refresh. That single difference is threaded as the
// onModelFallback callback. Everything else is shared verbatim so the two
// handlers can't drift.

import (
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// inferenceAdmissionParams bundles the per-request inputs the shared routing
// preflight needs. model is the resolved build id; the preflight may swap it to
// a Previous build via an alias fallback and returns the final value.
type inferenceAdmissionParams struct {
	model                  string
	publicModel            string
	stream                 bool
	estimatedPromptTokens  int
	requestedMaxTokens     int
	requiresVision         bool
	hasTools               bool
	modelMaxContext        int
	allowedProviderSerials []string
	deadline               time.Duration
	policy                 selfRoutePolicy
	// refundReservation releases any pre-flight balance reservation before a
	// terminal rejection. Must be non-nil (a no-op closure on the free paths).
	refundReservation func()
	// onModelFallback refreshes the forward body after an alias fallback rewrote
	// parsed["model"] to a Previous build. It returns ok=false when it wrote a
	// terminal error itself (e.g. the Responses→chat lowering failed), in which
	// case the preflight reports handled=true. Generic paths that rebuild the
	// body from parsed at dispatch pass nil (no refresh needed).
	onModelFallback func(newModel string) (ok bool)
}

// runInferenceAdmission performs the shared routing/capacity preflight for both
// inference handlers. On a rejection it writes the exact terminal response
// (refunding the reservation) and returns handled=true; on success it returns
// the (possibly fallback-updated) build model and handled=false. Self-route and
// prefer modes short-circuit the public capacity gate exactly as before.
func (s *Server) runInferenceAdmission(w http.ResponseWriter, r *http.Request, parsed map[string]any, p inferenceAdmissionParams) (string, bool) {
	model := p.model
	publicModel := p.publicModel
	refundReservation := p.refundReservation

	// Self-route pre-flight: confirm the caller owns an online machine that can
	// serve this model, with precise errors and no fallback to the paid fleet.
	if p.policy.enabled {
		if s.selfRouteUnavailable(w, r, p.policy.ownerAccountID, model) {
			refundReservation()
			return model, true
		}
		return model, false
	}
	if p.policy.prefer {
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
	candidateCount, capacityRejections, modelTooLarge, bestTTFT, hasTTFT := s.registry.QuickCapacityCheckWithTTFTForRequest(model, p.estimatedPromptTokens, p.requestedMaxTokens, registry.RequestTraits{HasTools: p.hasTools}, p.requiresVision, p.allowedProviderSerials...)
	if candidateCount == 0 && capacityRejections > 0 {
		if fallbackModel, fallbackCandidates, fallbackRejections, fallbackTooLarge, fallbackTTFT, fallbackHasTTFT, switched := s.maybeFallbackAlias(parsed, aliasFallbackCapacity, publicModel, model, p.estimatedPromptTokens, p.requestedMaxTokens, 0, registry.RequestTraits{HasTools: p.hasTools}, p.requiresVision, p.allowedProviderSerials); switched {
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
	if s.shedIfUnservable(w, r, parsed, publicModel, model, p.modelMaxContext, p.stream, p.estimatedPromptTokens, p.requestedMaxTokens, p.requiresVision, p.hasTools, p.allowedProviderSerials, refundReservation) {
		return model, true
	}
	if candidateCount == 0 && capacityRejections == 0 && modelTooLarge > 0 {
		// Providers serve this model but none can ever fit it — non-retryable.
		// Surface a clear 503 instead of a 429 the client would retry forever.
		refundReservation()
		s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:model_too_large"})
		s.recordRejection(rejectionInfo{
			r:                       r,
			stage:                   "preflight_capacity",
			reasonCode:              "model_too_large",
			httpStatus:              http.StatusServiceUnavailable,
			keyID:                   keyIDFromContext(r.Context()),
			consumerKeyHash:         store.HashKey(consumerKeyFromContext(r.Context())),
			requestedModel:          publicModel,
			resolvedModel:           model,
			stream:                  p.stream,
			estimatedPromptTokens:   p.estimatedPromptTokens,
			requestedMaxTokens:      p.requestedMaxTokens,
			requiresVision:          p.requiresVision,
			hasTools:                p.hasTools,
			params:                  rejectionSamplingParams(parsed),
			servabilityComputed:     true,
			candidateCount:          candidateCount,
			capacityRejections:      capacityRejections,
			modelTooLargeRejections: modelTooLarge,
			bestTTFTMs:              ttftMsForRejection(bestTTFT, hasTTFT),
		})
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_unavailable",
			fmt.Sprintf("model %q is too large for any currently available provider", publicModel),
			withCode("model_unavailable")))
		return model, true
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
		// Dedicated-family models (e.g. Gemma 4) bypass queue-before-shed when
		// their dedicated boxes are saturated: holding an OpenRouter request in
		// the 120s queue would blow its TTFT SLA, so shed immediately with a
		// 429 + Retry-After for a clean failover rather than waiting on a
		// dedicated slot that may not free in time.
		if s.queueBeforeShedEnabled() && !s.registry.IsDedicatedModel(model) {
			s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:capacity_queue_spill"})
		} else {
			// Fast-shed: immediate 429 (always for dedicated models; for every
			// model when queue-before-shed is disabled).
			retryAfter := s.estimateRetryAfter(model)
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
			refundReservation()
			s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:capacity_429"})
			s.recordRejection(rejectionInfo{
				r:                       r,
				stage:                   "preflight_capacity",
				reasonCode:              "machine_busy",
				httpStatus:              http.StatusTooManyRequests,
				keyID:                   keyIDFromContext(r.Context()),
				consumerKeyHash:         store.HashKey(consumerKeyFromContext(r.Context())),
				requestedModel:          publicModel,
				resolvedModel:           model,
				stream:                  p.stream,
				estimatedPromptTokens:   p.estimatedPromptTokens,
				requestedMaxTokens:      p.requestedMaxTokens,
				requiresVision:          p.requiresVision,
				hasTools:                p.hasTools,
				retryAfterMs:            retryAfter * 1000,
				params:                  rejectionSamplingParams(parsed),
				servabilityComputed:     true,
				candidateCount:          candidateCount,
				capacityRejections:      capacityRejections,
				modelTooLargeRejections: modelTooLarge,
				bestTTFTMs:              ttftMsForRejection(bestTTFT, hasTTFT),
			})
			writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
				fmt.Sprintf("all providers for model %q are at capacity — retry after %ds", publicModel, retryAfter),
				withCode("rate_limit_exceeded")))
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
		s.registry.RecordWarmPoolCapacityReject(model)
		s.triggerWarmPool()
		if s.coldDispatchEnabled() && s.coldSpillAvailable(model, registry.RequestTraits{HasTools: p.hasTools}, p.requiresVision, p.allowedProviderSerials) {
			s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:cold_dispatch_spill"})
			// Fall through to dispatch+queue; reservation kept.
		} else if s.registry.IsDedicatedModel(model) && s.registry.HasProviderForModel(model, p.allowedProviderSerials...) {
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
			s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:dedicated_capacity_429"})
			s.recordRejection(rejectionInfo{
				r:                       r,
				stage:                   "preflight_capacity",
				reasonCode:              "machine_busy",
				httpStatus:              http.StatusTooManyRequests,
				keyID:                   keyIDFromContext(r.Context()),
				consumerKeyHash:         store.HashKey(consumerKeyFromContext(r.Context())),
				requestedModel:          publicModel,
				resolvedModel:           model,
				stream:                  p.stream,
				estimatedPromptTokens:   p.estimatedPromptTokens,
				requestedMaxTokens:      p.requestedMaxTokens,
				requiresVision:          p.requiresVision,
				hasTools:                p.hasTools,
				retryAfterMs:            retryAfter * 1000,
				params:                  rejectionSamplingParams(parsed),
				servabilityComputed:     true,
				candidateCount:          candidateCount,
				capacityRejections:      capacityRejections,
				modelTooLargeRejections: modelTooLarge,
				bestTTFTMs:              ttftMsForRejection(bestTTFT, hasTTFT),
			})
			writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
				fmt.Sprintf("no provider dedicated to model %q is available right now — retry after %ds", publicModel, retryAfter),
				withCode("rate_limit_exceeded")))
			return model, true
		} else {
			// None of these clear by a slot freeing up, so queueing for up to
			// 120s only adds misleading latency before the same error. Fail
			// fast with a retryable 503 + Retry-After (OpenRouter treats 503
			// as unavailable, not a uptime-penalised error here because the
			// body is explicit). This mirrors the trait fast-fails above for
			// the transient-cooldown case they cannot see.
			retryAfter := s.estimateRetryAfter(model)
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
			refundReservation()
			s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:no_eligible_provider"})
			s.recordRejection(rejectionInfo{
				r:                       r,
				stage:                   "preflight_capacity",
				reasonCode:              "no_provider",
				httpStatus:              http.StatusServiceUnavailable,
				keyID:                   keyIDFromContext(r.Context()),
				consumerKeyHash:         store.HashKey(consumerKeyFromContext(r.Context())),
				requestedModel:          publicModel,
				resolvedModel:           model,
				stream:                  p.stream,
				estimatedPromptTokens:   p.estimatedPromptTokens,
				requestedMaxTokens:      p.requestedMaxTokens,
				requiresVision:          p.requiresVision,
				hasTools:                p.hasTools,
				retryAfterMs:            retryAfter * 1000,
				params:                  rejectionSamplingParams(parsed),
				servabilityComputed:     true,
				candidateCount:          candidateCount,
				capacityRejections:      capacityRejections,
				modelTooLargeRejections: modelTooLarge,
				bestTTFTMs:              ttftMsForRejection(bestTTFT, hasTTFT),
			})
			writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_unavailable",
				fmt.Sprintf("no provider for model %q is available right now — retry after %ds", publicModel, retryAfter),
				withCode("model_unavailable")))
			return model, true
		}
	}
	if ttftTooSlow(bestTTFT, hasTTFT, ttftThreshold) {
		if !s.ttftHardReject {
			// Soft TTFT gate (default): a provider passed every routing and
			// capacity gate, and pr.MaxTTFTMs is left 0 in soft mode, so the
			// dispatch path serves the best-available provider instead of
			// re-rejecting (P1 fix). Do NOT divert to an older alias build here
			// (P2 fix) — the desired build is routable. A soft-serve over the
			// deadline is still a TTFT near-miss, so feed the autoscaler so it
			// grows warm capacity for this model.
			s.registry.RecordWarmPoolTTFTMiss(model, ttftThreshold)
			s.triggerWarmPool()
			s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:ttft_soft_served"})
		} else if fallbackModel, _, _, _, fallbackTTFT, fallbackHasTTFT, switched := s.maybeFallbackAlias(parsed, aliasFallbackTTFT, publicModel, model, p.estimatedPromptTokens, p.requestedMaxTokens, ttftThreshold, registry.RequestTraits{HasTools: p.hasTools}, p.requiresVision, p.allowedProviderSerials); switched {
			model = fallbackModel
			if p.onModelFallback != nil && !p.onModelFallback(model) {
				return model, true
			}
		} else {
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
				keyID:                   keyIDFromContext(r.Context()),
				consumerKeyHash:         store.HashKey(consumerKeyFromContext(r.Context())),
				requestedModel:          publicModel,
				resolvedModel:           model,
				stream:                  p.stream,
				estimatedPromptTokens:   p.estimatedPromptTokens,
				requestedMaxTokens:      p.requestedMaxTokens,
				requiresVision:          p.requiresVision,
				hasTools:                p.hasTools,
				params:                  rejectionSamplingParams(parsed),
				servabilityComputed:     true,
				candidateCount:          candidateCount,
				capacityRejections:      capacityRejections,
				modelTooLargeRejections: modelTooLarge,
				bestTTFTMs:              float64(retryTTFT.Milliseconds()),
			})
			s.writeTTFTTooSlow(w, retryModel, publicModel, retryTTFT, ttftThreshold)
			return model, true
		}
	}
	return model, false
}
