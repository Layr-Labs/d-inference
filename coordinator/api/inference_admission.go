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
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// balanceReservationParams bundles the inputs to the shared pre-flight balance
// reservation.
type balanceReservationParams struct {
	model                 string
	publicModel           string
	billingPromptTokens   int
	estimatedPromptTokens int
	requestedMaxTokens    int
	stream                bool
	requiresVision        bool
	hasTools              bool
	policy                selfRoutePolicy
}

// reserveInferenceBalance performs the shared pre-flight balance reservation +
// per-key spend cap for both inference handlers. Self-route (policy.enabled) and
// a nil billing backend skip it (the request is free). On a spend-cap or
// insufficient-funds rejection it writes the exact terminal response and returns
// handled=true; otherwise it returns the reserved amount and whether it was a
// service-account reservation. The post-inference charge refunds any unused
// portion; the routing estimate is kept separate so capacity checks aren't
// over-inflated.
func (s *Server) reserveInferenceBalance(w http.ResponseWriter, r *http.Request, parsed map[string]any, p balanceReservationParams) (reservedMicroUSD int64, serviceReservation bool, handled bool) {
	// Self-route is free: skip the pre-flight balance reservation and the
	// per-key spend cap entirely. A zero-balance owner must never be blocked
	// from running on their own machine, and a self_route_only key never spends.
	if s.billing == nil || p.policy.enabled {
		return 0, false, false
	}
	consumerKey := consumerKeyFromContext(r.Context())
	// Normally the byte-count billing bound dominates the routing estimate. A
	// remote media URL is the exception: its short URL is rewritten after this
	// gate into hundreds/thousands of vision soft tokens. Reserve against the
	// larger bound so a low-balance caller cannot trigger coordinator egress and
	// only then fail the platform-price balance check.
	reservationPromptTokens := max(p.billingPromptTokens, p.estimatedPromptTokens)
	reservedMicroUSD = s.reservationCost(p.model, reservationPromptTokens, p.requestedMaxTokens)
	// Per-key spend cap (phase 1) — checked before the reservation so a capped
	// key never debits the account ledger.
	if msg, ok := s.checkKeySpendCap(r.Context(), reservedMicroUSD); !ok {
		s.recordRejection(rejectionInfo{
			r:                     r,
			stage:                 "balance",
			reasonCode:            "insufficient_quota",
			httpStatus:            http.StatusPaymentRequired,
			keyID:                 keyIDFromContext(r.Context()),
			consumerKeyHash:       store.HashKey(consumerKeyFromContext(r.Context())),
			requestedModel:        p.publicModel,
			resolvedModel:         p.model,
			stream:                p.stream,
			estimatedPromptTokens: p.estimatedPromptTokens,
			requestedMaxTokens:    p.requestedMaxTokens,
			requiresVision:        p.requiresVision,
			hasTools:              p.hasTools,
			params:                rejectionSamplingParams(parsed),
		})
		writeJSON(w, http.StatusPaymentRequired, errorResponse("insufficient_quota", msg, withCode("insufficient_quota")))
		return reservedMicroUSD, false, true
	}
	var err error
	serviceReservation, err = s.reserveInitialBalance(consumerKey, p.model, reservedMicroUSD)
	if err != nil {
		if errors.Is(err, store.ErrInsufficientBalance) {
			s.recordRejection(rejectionInfo{
				r:                     r,
				stage:                 "balance",
				reasonCode:            "insufficient_funds",
				httpStatus:            http.StatusPaymentRequired,
				keyID:                 keyIDFromContext(r.Context()),
				consumerKeyHash:       store.HashKey(consumerKeyFromContext(r.Context())),
				requestedModel:        p.publicModel,
				resolvedModel:         p.model,
				stream:                p.stream,
				estimatedPromptTokens: p.estimatedPromptTokens,
				requestedMaxTokens:    p.requestedMaxTokens,
				requiresVision:        p.requiresVision,
				hasTools:              p.hasTools,
				params:                rejectionSamplingParams(parsed),
			})
			writeJSON(w, http.StatusPaymentRequired, errorResponse("insufficient_funds",
				"your balance is too low for this request — add funds at /billing or lower max_tokens", withCode("insufficient_quota")))
		} else {
			s.logger.Error("balance reservation failed (DB error)", "consumer_key", consumerKey, "error", err)
			s.writeServiceUnavailable(w, p.model)
		}
		return reservedMicroUSD, serviceReservation, true
	}
	return reservedMicroUSD, serviceReservation, false
}

// topUpReservationForInlinedMedia re-reserves after remote media has been
// fetched and inlined into parsed.
//
// reserveInferenceBalance runs BEFORE the fetch (deliberately — network I/O must
// stay behind the cost gates), so for a remote media URL it reserves against a
// body where the image is ~100 bytes of URL text. That breaks the invariant the
// rest of the money path depends on: estimateBillingPromptTokens is documented
// as a guaranteed upper bound (len(bytes) >= tokens for any BPE tokenizer), and
// for an inline data: URI it is. The flat routing floor (300 image / 1500 video
// soft tokens) is NOT an upper bound — a provider samples up to 32 video frames
// at ~282 soft tokens each — and settlement clamps any overage at 2x the
// reservation as a fraud circuit-breaker, so the shortfall is silently written
// off AND the provider payout is recomputed from the clamped total. Recomputing
// the byte bound over the inlined body restores the guarantee.
//
// p.billingPromptTokens must already be recomputed from the mutated parsed.
// Returns the reservation now held (unchanged when no top-up was needed or when
// the top-up failed) and handled=true after writing a terminal response, in
// which case the caller must refund and return.
func (s *Server) topUpReservationForInlinedMedia(w http.ResponseWriter, r *http.Request, parsed map[string]any, p balanceReservationParams, currentMicroUSD int64) (reservedMicroUSD int64, handled bool) {
	// Same skips as reserveInferenceBalance: self-route is free and a nil billing
	// backend never reserved anything to top up.
	if s.billing == nil || p.policy.enabled || currentMicroUSD <= 0 {
		return currentMicroUSD, false
	}
	want := s.reservationCost(p.model, max(p.billingPromptTokens, p.estimatedPromptTokens), p.requestedMaxTokens)
	if want <= currentMicroUSD {
		return currentMicroUSD, false
	}
	reject := func(reasonCode, code, msg string) {
		s.recordRejection(rejectionInfo{
			r:                     r,
			stage:                 "balance",
			reasonCode:            reasonCode,
			httpStatus:            http.StatusPaymentRequired,
			keyID:                 keyIDFromContext(r.Context()),
			consumerKeyHash:       store.HashKey(consumerKeyFromContext(r.Context())),
			requestedModel:        p.publicModel,
			resolvedModel:         p.model,
			stream:                p.stream,
			estimatedPromptTokens: p.estimatedPromptTokens,
			requestedMaxTokens:    p.requestedMaxTokens,
			requiresVision:        p.requiresVision,
			hasTools:              p.hasTools,
			params:                rejectionSamplingParams(parsed),
		})
		s.ddIncr("billing.media_reservation_topup", []string{"model:" + p.model, "outcome:rejected"})
		writeJSON(w, http.StatusPaymentRequired, errorResponse(code, msg, withCode("insufficient_quota")))
	}
	// Cap check against the new TOTAL, matching reserveAdditionalForProvider.
	if msg, ok := s.checkKeySpendCap(r.Context(), want); !ok {
		reject("insufficient_quota", "insufficient_quota", msg)
		return currentMicroUSD, true
	}
	consumerKey := consumerKeyFromContext(r.Context())
	// Charge only the delta; reserveInitialBalance re-derives the same
	// service-vs-ledger mode for this account, so the hold stays consistent.
	if _, err := s.reserveInitialBalance(consumerKey, p.model, want-currentMicroUSD); err != nil {
		if errors.Is(err, store.ErrInsufficientBalance) {
			reject("insufficient_funds", "insufficient_funds",
				"your balance is too low for this request once the linked media is included — add funds at /billing, use smaller media, or lower max_tokens")
		} else {
			s.logger.Error("media reservation top-up failed (DB error)", "consumer_key", consumerKey, "error", err)
			s.ddIncr("billing.media_reservation_topup", []string{"model:" + p.model, "outcome:error"})
			s.writeServiceUnavailable(w, p.model)
		}
		return currentMicroUSD, true
	}
	s.ddIncr("billing.media_reservation_topup", []string{"model:" + p.model, "outcome:reserved"})
	return want, false
}

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
	policy                    selfRoutePolicy
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

// runInferenceAdmission performs the shared routing/capacity preflight for both
// inference handlers. On a rejection it writes the exact terminal response
// (refunding the reservation) and returns handled=true; on success it returns
// the (possibly fallback-updated) build model and handled=false. Self-route and
// prefer modes short-circuit the public capacity gate exactly as before.
func (s *Server) runInferenceAdmission(w http.ResponseWriter, r *http.Request, parsed map[string]any, p inferenceAdmissionParams) (string, bool) {
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
		target, ok := s.registry.AliasTarget(publicModel)
		if ok && target.Desired == currentModel && target.Previous != "" {
			return modelTraits(target.Previous)
		}
		return modelTraits(currentModel)
	}
	rejectProviderBodyTooLarge := func(providerBodyErr error) bool {
		if !errors.Is(providerBodyErr, errProviderBodyTooLarge) {
			return false
		}
		refundReservation()
		s.recordRejection(rejectionInfo{
			r:                     r,
			stage:                 "validation",
			reasonCode:            "payload_too_large",
			httpStatus:            http.StatusRequestEntityTooLarge,
			keyID:                 keyIDFromContext(r.Context()),
			consumerKeyHash:       store.HashKey(consumerKeyFromContext(r.Context())),
			requestedModel:        publicModel,
			resolvedModel:         model,
			stream:                p.stream,
			estimatedPromptTokens: p.estimatedPromptTokens,
			requestedMaxTokens:    p.requestedMaxTokens,
			requiresVision:        p.requiresVision,
			hasTools:              p.hasTools,
			requestBodyBytes:      oversizedProviderBodyBytes(providerBodyErr),
			params:                rejectionSamplingParams(parsed),
			servabilityComputed:   true,
		})
		writeJSON(w, http.StatusRequestEntityTooLarge, errorResponse(
			"invalid_request_error", providerBodyErr.Error(),
			withCode("payload_too_large")))
		return true
	}

	// Self-route pre-flight: confirm the caller owns an online machine that can
	// serve this model, with precise errors and no fallback to the paid fleet.
	if p.policy.enabled {
		traits := modelTraits(model)
		if traits.MinPrefixCacheProtocol > 0 && p.providerBodyErrorForModel != nil {
			_, servesWithFloor := s.registry.OwnedProviderSummary(
				p.policy.ownerAccountID, model, traits, p.requiresVision)
			withoutProtocolFloor := traits
			withoutProtocolFloor.MinPrefixCacheProtocol = 0
			_, servesWithoutFloor := s.registry.OwnedProviderSummary(
				p.policy.ownerAccountID, model, withoutProtocolFloor, p.requiresVision)
			if servesWithFloor == 0 &&
				servesWithoutFloor > 0 &&
				rejectProviderBodyTooLarge(p.providerBodyErrorForModel(model)) {
				return model, true
			}
		}
		if s.selfRouteUnavailable(w, r, p.policy.ownerAccountID, model, traits, p.requiresVision) {
			refundReservation()
			return model, true
		}
		return model, false
	}
	if p.policy.prefer {
		traits := modelTraits(model)
		if traits.MinPrefixCacheProtocol > 0 && p.providerBodyErrorForModel != nil {
			_, ownedWithFloor := s.registry.OwnedProviderSummary(
				p.policy.ownerAccountID, model, traits, p.requiresVision)
			publicWithFloor, publicCapacityWithFloor, _ :=
				s.registry.QuickCapacityCheckForRequest(
					model,
					p.estimatedPromptTokens,
					p.requestedMaxTokens,
					traits,
					p.requiresVision,
					p.allowedProviderSerials...,
				)
			withoutProtocolFloor := traits
			withoutProtocolFloor.MinPrefixCacheProtocol = 0
			_, ownedWithoutFloor := s.registry.OwnedProviderSummary(
				p.policy.ownerAccountID, model, withoutProtocolFloor, p.requiresVision)
			publicWithoutFloor, publicCapacityWithoutFloor, _ :=
				s.registry.QuickCapacityCheckForRequest(
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
	candidateCount, capacityRejections, modelTooLarge, bestTTFT, hasTTFT := s.registry.QuickCapacityCheckWithTTFTForRequest(model, p.estimatedPromptTokens, p.requestedMaxTokens, modelTraits(model), p.requiresVision, p.allowedProviderSerials...)
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
	var providerBodyErr error
	if p.providerBodyErrorForModel != nil {
		providerBodyErr = p.providerBodyErrorForModel(model)
	}
	bodyIncompatibilityCausedNoCandidates := false
	if errors.Is(providerBodyErr, errProviderBodyTooLarge) {
		withoutProtocolFloor := modelTraits(model)
		withoutProtocolFloor.MinPrefixCacheProtocol = 0
		baselineCandidates, baselineCapacity, _ := s.registry.QuickCapacityCheckForRequest(
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
			s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:capacity_queue_spill"})
		} else {
			// Fast-shed: immediate 429 when queue-before-shed is disabled.
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
		if s.coldDispatchEnabled() && s.coldSpillAvailable(model, modelTraits(model), p.requiresVision, p.allowedProviderSerials) {
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
			s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:no_eligible_provider"})
			s.recordRejection(rejectionInfo{
				r:                       r,
				stage:                   "preflight_capacity",
				reasonCode:              "no_provider",
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
				fmt.Sprintf("no provider for model %q is available right now — retry after %ds", publicModel, retryAfter),
				withCode("rate_limit_exceeded")))
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
		} else if fallbackModel, _, _, _, fallbackTTFT, fallbackHasTTFT, switched := s.maybeFallbackAlias(parsed, aliasFallbackTTFT, publicModel, model, p.estimatedPromptTokens, p.requestedMaxTokens, ttftThreshold, fallbackTraits(model), p.requiresVision, p.allowedProviderSerials); switched {
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
