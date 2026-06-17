package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// handleChatCompletions handles POST /v1/chat/completions.
//
// This is the main inference endpoint. It validates the request, finds an
// available provider for the requested model, forwards the request via
// WebSocket, and either streams SSE chunks or assembles a complete response.
//
// The raw request body is passed through to the provider, preserving all
// OpenAI-compatible fields (tools, tool_choice, response_format, top_p, etc.)
// that would otherwise be lost if we parsed into a typed struct.
func (s *Server) handleChatCompletions(w http.ResponseWriter, r *http.Request) {
	timing := &registry.RequestTiming{ReceivedAt: time.Now()}

	// Shared prelude: read body, normalize tool schemas, parse, require a model,
	// enforce the per-key model allowlist. (See parseInferencePrelude.)
	prelude, ok := s.parseInferencePrelude(w, r)
	if !ok {
		return
	}
	rawBody := prelude.rawBody
	parsed := prelude.parsed
	model := prelude.model

	// Accept either chat completions format (messages) or Responses API
	// format (input). The provider's backend handles both natively.
	messages, _ := parsed["messages"].([]any)
	input := parsed["input"]
	if len(messages) == 0 && input == nil {
		s.recordRejection(rejectionInfo{
			r:               r,
			stage:           "validation",
			reasonCode:      "messages_required",
			httpStatus:      http.StatusBadRequest,
			keyID:           keyIDFromContext(r.Context()),
			consumerKeyHash: store.HashKey(consumerKeyFromContext(r.Context())),
			requestedModel:  model,
			params:          rejectionSamplingParams(parsed),
		})
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "messages or input is required"))
		return
	}

	// Multiple choices per request are not supported — fail loudly instead of
	// silently returning a single choice the consumer didn't ask for.
	if copies, ok := intFromRequestValue(parsed["n"]); ok && copies > 1 {
		s.recordRejection(rejectionInfo{
			r:               r,
			stage:           "validation",
			reasonCode:      "bad_param",
			httpStatus:      http.StatusBadRequest,
			keyID:           keyIDFromContext(r.Context()),
			consumerKeyHash: store.HashKey(consumerKeyFromContext(r.Context())),
			requestedModel:  model,
			n:               copies,
			params:          rejectionSamplingParams(parsed),
		})
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			"n > 1 is not supported", withParam("n")))
		return
	}

	allowedProviderSerials, hasProviderAllowlist, err := parseProviderSerialAllowlist(parsed)
	if err != nil {
		s.recordRejection(rejectionInfo{
			r:               r,
			stage:           "validation",
			reasonCode:      "bad_param",
			httpStatus:      http.StatusBadRequest,
			keyID:           keyIDFromContext(r.Context()),
			consumerKeyHash: store.HashKey(consumerKeyFromContext(r.Context())),
			requestedModel:  model,
			params:          rejectionSamplingParams(parsed),
		})
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", err.Error()))
		return
	}
	if hasProviderAllowlist && stripProviderRoutingFields(parsed) {
		rawBody, _ = marshalForwardBody(parsed)
	}

	// "Use my own machine, for free" opt-in. The signal is the
	// X-Darkbloom-Route header (OpenAI-client-safe: invisible to the body
	// schema) OR a per-key hard ceiling. The header can only *request*
	// self-routing; it cannot name a machine — ownership is matched on the
	// coordinator-stamped provider AccountID, so nothing here is forgeable.
	policy := s.resolveSelfRoutePolicy(r)

	// Resolve a public alias (e.g. "gemma-4-26b") to a concrete build id, now
	// that routing constraints (serial allowlist / self-route) are known so the
	// pick only considers builds the constrained provider set can actually
	// serve. From here on `model` is the build (routing/billing/serving) while
	// `publicModel` is echoed back so the consumer never sees the quant.
	buildModel, publicModel, resolvedBody, ok := s.resolveRequestedModel(
		parsed, rawBody, model, allowedProviderSerials, policy)
	if !ok {
		s.recordRejection(rejectionInfo{
			r:               r,
			stage:           "model_resolution",
			reasonCode:      "model_unavailable",
			httpStatus:      http.StatusServiceUnavailable,
			keyID:           keyIDFromContext(r.Context()),
			consumerKeyHash: store.HashKey(consumerKeyFromContext(r.Context())),
			requestedModel:  model,
			params:          rejectionSamplingParams(parsed),
		})
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_unavailable",
			fmt.Sprintf("model %q has no available build right now", model), withParam("model")))
		return
	}
	model, rawBody = buildModel, resolvedBody

	// Vision gating: a request carrying image/video input must land on a provider
	// advertising a vision-capable (VLM) build of this model, or the media is
	// silently dropped and the answer is image-blind. Fail fast with a clear error
	// when the fleet has no such provider (e.g. before the gemma fleet finishes
	// updating to 0.6.0); the routing layer enforces the same gate per dispatch.
	requiresVision := detectMediaRequirement(parsed)
	// Tool-bearing requests are routed only to providers that can render tool
	// schemas without crashing (version floor + template_render_ok gate);
	// detected here, alongside the media gate, while the parsed body is hot.
	hasTools := requestHasTools(parsed)
	cacheAffinityKey := requestCacheAffinityKey(parsed)
	// Shared media/tools fail-fast. Chat completions additionally rejects media
	// sent via the Responses API surface (input-without-messages), because the
	// Responses→chat lowering doesn't carry image/video parts through.
	if s.visionToolsFailFast(w, model, publicModel, requiresVision, hasTools,
		input != nil && len(messages) == 0, policy, allowedProviderSerials) {
		return
	}

	isResponsesAPI := input != nil && len(messages) == 0

	// Inject model-specific defaults from the registry: reasoning_parser
	// and max_tokens bound. Single DB lookup (cached for platform prices).
	maxOutputBound := defaultMaxOutputTokens
	if rec, err := s.store.GetModelRegistryRecord(model); err == nil {
		// Reasoning parser from runtime_parameters.
		if _, hasRP := parsed["reasoning_parser"]; !hasRP && rec.RuntimeParameters != nil {
			if rp, ok := rec.RuntimeParameters["reasoning_parser"]; ok {
				parsed["reasoning_parser"] = rp
				rawBody, _ = marshalForwardBody(parsed)
			}
		}
		// Use the registry's max_output_length as the default max_tokens
		// bound instead of the hardcoded 8192. This lets models like
		// GPT-OSS 20B (32K output) generate longer responses when the
		// consumer omits max_tokens.
		if rec.MaxOutputLength > 0 {
			maxOutputBound = rec.MaxOutputLength
		}
	}

	// Bound the generation so the pre-flight reservation covers it. If the
	// consumer didn't set max_tokens, inject the model's max_output_length
	// (or defaultMaxOutputTokens as fallback). Without this bound the
	// provider could return more tokens than we reserved for, and the
	// silent post-inference charge failure would hand the consumer free
	// inference (GitHub issue #33).
	if ensureMaxTokensBound(parsed, isResponsesAPI, maxOutputBound) {
		rawBody, _ = marshalForwardBody(parsed)
	}

	stream, _ := parsed["stream"].(bool)
	estimatedPromptTokens := estimatePromptTokens(parsed)
	billingPromptTokens := estimateBillingPromptTokens(parsed)
	requestedMaxTokens := estimateRequestedMaxTokens(parsed)
	deadline := ttftDeadline(estimatedPromptTokens)
	timing.ParsedAt = time.Now()

	if isResponsesAPI {
		providerParsed, err := responsesRequestToChatCompletions(parsed)
		if err != nil {
			s.recordRejection(rejectionInfo{
				r:                     r,
				stage:                 "validation",
				reasonCode:            "bad_param",
				httpStatus:            http.StatusBadRequest,
				keyID:                 keyIDFromContext(r.Context()),
				consumerKeyHash:       store.HashKey(consumerKeyFromContext(r.Context())),
				requestedModel:        publicModel,
				resolvedModel:         model,
				stream:                stream,
				estimatedPromptTokens: estimatedPromptTokens,
				requestedMaxTokens:    requestedMaxTokens,
				requiresVision:        requiresVision,
				hasTools:              hasTools,
				params:                rejectionSamplingParams(parsed),
			})
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", err.Error()))
			return
		}
		rawBody, _ = marshalForwardBody(providerParsed)
	}

	// Per-account token rate limiting (ITPM/OTPM) — the industry-standard
	// token throttle alongside RPM. Charged upfront from the input estimate
	// and the bounded max_tokens (OpenAI-style). Runs before the balance
	// reservation so a throttled request never touches billing.
	tokenAdmission, ok := s.applyTokenRateLimitWithAdmission(w, r, estimatedPromptTokens, requestedMaxTokens)
	if !ok {
		return
	}

	// Pre-flight balance reservation — atomically debit the worst-case cost
	// using the byte-length upper bound for prompt tokens (guaranteed >=
	// actual tokens for any BPE tokenizer) plus max_tokens we just bounded
	// the generation to. The post-inference charge refunds any unused
	// portion. The routing estimate (estimatedPromptTokens, len/4) is kept
	// separate so scheduler capacity checks aren't over-inflated.
	var reservedMicroUSD int64
	serviceReservation := false
	// Self-route is free: skip the pre-flight balance reservation and the
	// per-key spend cap entirely. A zero-balance owner must never be blocked
	// from running on their own machine, and a self_route_only key never spends.
	if s.billing != nil && !policy.enabled {
		consumerKey := consumerKeyFromContext(r.Context())
		reservedMicroUSD = s.reservationCost(model, billingPromptTokens, requestedMaxTokens)
		// Per-key spend cap (phase 1) — checked before the reservation so a
		// capped key never debits the account ledger.
		if msg, ok := s.checkKeySpendCap(r.Context(), reservedMicroUSD); !ok {
			s.recordRejection(rejectionInfo{
				r:                     r,
				stage:                 "balance",
				reasonCode:            "insufficient_quota",
				httpStatus:            http.StatusPaymentRequired,
				keyID:                 keyIDFromContext(r.Context()),
				consumerKeyHash:       store.HashKey(consumerKeyFromContext(r.Context())),
				requestedModel:        publicModel,
				resolvedModel:         model,
				stream:                stream,
				estimatedPromptTokens: estimatedPromptTokens,
				requestedMaxTokens:    requestedMaxTokens,
				requiresVision:        requiresVision,
				hasTools:              hasTools,
				params:                rejectionSamplingParams(parsed),
			})
			writeJSON(w, http.StatusPaymentRequired, errorResponse("insufficient_quota", msg, withCode("insufficient_quota")))
			return
		}
		var err error
		serviceReservation, err = s.reserveInitialBalance(consumerKey, model, reservedMicroUSD)
		if err != nil {
			if errors.Is(err, store.ErrInsufficientBalance) {
				s.recordRejection(rejectionInfo{
					r:                     r,
					stage:                 "balance",
					reasonCode:            "insufficient_funds",
					httpStatus:            http.StatusPaymentRequired,
					keyID:                 keyIDFromContext(r.Context()),
					consumerKeyHash:       store.HashKey(consumerKeyFromContext(r.Context())),
					requestedModel:        publicModel,
					resolvedModel:         model,
					stream:                stream,
					estimatedPromptTokens: estimatedPromptTokens,
					requestedMaxTokens:    requestedMaxTokens,
					requiresVision:        requiresVision,
					hasTools:              hasTools,
					params:                rejectionSamplingParams(parsed),
				})
				writeJSON(w, http.StatusPaymentRequired, errorResponse("insufficient_funds",
					"your balance is too low for this request — add funds at /billing or lower max_tokens", withCode("insufficient_quota")))
			} else {
				s.logger.Error("balance reservation failed (DB error)", "consumer_key", consumerKey, "error", err)
				s.writeServiceUnavailable(w, model)
			}
			return
		}
	}
	timing.ReservedAt = time.Now()

	// Refund reservation on early errors (before inference starts).
	refundReservation := func() {
		if reservedMicroUSD > 0 {
			s.releaseInitialReservation(consumerKeyFromContext(r.Context()), model, reservedMicroUSD, serviceReservation)
		}
	}

	// Reject requests for models not in the catalog.
	if !s.registry.IsModelInCatalog(model) {
		refundReservation()
		s.recordRejection(rejectionInfo{
			r:                     r,
			stage:                 "model_resolution",
			reasonCode:            "model_not_found",
			httpStatus:            http.StatusNotFound,
			keyID:                 keyIDFromContext(r.Context()),
			consumerKeyHash:       store.HashKey(consumerKeyFromContext(r.Context())),
			requestedModel:        publicModel,
			resolvedModel:         model,
			stream:                stream,
			estimatedPromptTokens: estimatedPromptTokens,
			requestedMaxTokens:    requestedMaxTokens,
			requiresVision:        requiresVision,
			hasTools:              hasTools,
			params:                rejectionSamplingParams(parsed),
		})
		writeJSON(w, http.StatusNotFound, errorResponse("model_not_found",
			fmt.Sprintf("model %q is not available — see /v1/models for supported models", publicModel), withParam("model")))
		return
	}

	// Self-route pre-flight: confirm the caller owns an online machine that can
	// serve this model, with precise errors and no fallback to the paid fleet.
	if policy.enabled {
		if s.selfRouteUnavailable(w, r, policy.ownerAccountID, model) {
			refundReservation()
			return
		}
	} else if policy.prefer {
		// Prefer mode: SKIP the public fleet pre-flight. QuickCapacityCheck has
		// no owner-trust relaxation, so it would spuriously 429/503 a request
		// whose own (idle, possibly un-enrolled / private-only) machine could
		// serve it while the public fleet is busy. Dispatch does owned-first
		// routing with a paid public fallback and the normal queue, which is the
		// correct gate for prefer.
	} else {
		ttftThreshold := deadline
		// Pre-flight capacity check: can ANY provider serve this model right
		// now? If not, return 429 immediately rather than queueing for up to
		// 120s. OpenRouter treats 429 as "rate limited" (no uptime penalty) vs
		// 503 which counts as downtime. Fast 429s also preserve our TTFT
		// metrics. Self-route skips this fleet-wide gate — it queues on the
		// owner's machine instead (handled below).
		candidateCount, capacityRejections, modelTooLarge, bestTTFT, hasTTFT := s.registry.QuickCapacityCheckWithTTFTForRequest(model, estimatedPromptTokens, requestedMaxTokens, registry.RequestTraits{HasTools: hasTools}, requiresVision, allowedProviderSerials...)
		if candidateCount == 0 && capacityRejections > 0 {
			if fallbackModel, fallbackCandidates, fallbackRejections, fallbackTooLarge, fallbackTTFT, fallbackHasTTFT, switched := s.maybeFallbackAliasCapacity(parsed, publicModel, model, estimatedPromptTokens, requestedMaxTokens, registry.RequestTraits{HasTools: hasTools}, requiresVision, allowedProviderSerials); switched {
				model = fallbackModel
				candidateCount, capacityRejections, modelTooLarge = fallbackCandidates, fallbackRejections, fallbackTooLarge
				bestTTFT, hasTTFT = fallbackTTFT, fallbackHasTTFT
				if isResponsesAPI {
					providerParsed, err := responsesRequestToChatCompletions(parsed)
					if err != nil {
						refundReservation()
						s.recordRejection(rejectionInfo{
							r:                     r,
							stage:                 "validation",
							reasonCode:            "bad_param",
							httpStatus:            http.StatusBadRequest,
							keyID:                 keyIDFromContext(r.Context()),
							consumerKeyHash:       store.HashKey(consumerKeyFromContext(r.Context())),
							requestedModel:        publicModel,
							resolvedModel:         model,
							stream:                stream,
							estimatedPromptTokens: estimatedPromptTokens,
							requestedMaxTokens:    requestedMaxTokens,
							requiresVision:        requiresVision,
							hasTools:              hasTools,
							params:                rejectionSamplingParams(parsed),
						})
						writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", err.Error()))
						return
					}
					rawBody, _ = marshalForwardBody(providerParsed)
				} else {
					rawBody, _ = marshalForwardBody(parsed)
				}
			}
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
				stream:                  stream,
				estimatedPromptTokens:   estimatedPromptTokens,
				requestedMaxTokens:      requestedMaxTokens,
				requiresVision:          requiresVision,
				hasTools:                hasTools,
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
			return
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
			if s.queueBeforeShedEnabled() {
				s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:capacity_queue_spill"})
			} else {
				// Legacy fast-shed: immediate 429.
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
					stream:                  stream,
					estimatedPromptTokens:   estimatedPromptTokens,
					requestedMaxTokens:      requestedMaxTokens,
					requiresVision:          requiresVision,
					hasTools:                hasTools,
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
				return
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
			if s.coldDispatchEnabled() && s.coldSpillAvailable(model, registry.RequestTraits{HasTools: hasTools}, requiresVision, allowedProviderSerials) {
				s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:cold_dispatch_spill"})
				// Fall through to dispatch+queue; reservation kept.
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
					stream:                  stream,
					estimatedPromptTokens:   estimatedPromptTokens,
					requestedMaxTokens:      requestedMaxTokens,
					requiresVision:          requiresVision,
					hasTools:                hasTools,
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
				return
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
			} else if fallbackModel, _, _, _, fallbackTTFT, fallbackHasTTFT, switched := s.maybeFallbackAliasTTFT(parsed, publicModel, model, estimatedPromptTokens, requestedMaxTokens, ttftThreshold, registry.RequestTraits{HasTools: hasTools}, requiresVision, allowedProviderSerials); switched {
				model = fallbackModel
				if isResponsesAPI {
					providerParsed, err := responsesRequestToChatCompletions(parsed)
					if err != nil {
						refundReservation()
						s.recordRejection(rejectionInfo{
							r:                     r,
							stage:                 "validation",
							reasonCode:            "bad_param",
							httpStatus:            http.StatusBadRequest,
							keyID:                 keyIDFromContext(r.Context()),
							consumerKeyHash:       store.HashKey(consumerKeyFromContext(r.Context())),
							requestedModel:        publicModel,
							resolvedModel:         model,
							stream:                stream,
							estimatedPromptTokens: estimatedPromptTokens,
							requestedMaxTokens:    requestedMaxTokens,
							requiresVision:        requiresVision,
							hasTools:              hasTools,
							params:                rejectionSamplingParams(parsed),
						})
						writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", err.Error()))
						return
					}
					rawBody, _ = marshalForwardBody(providerParsed)
				} else {
					rawBody, _ = marshalForwardBody(parsed)
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
					stream:                  stream,
					estimatedPromptTokens:   estimatedPromptTokens,
					requestedMaxTokens:      requestedMaxTokens,
					requiresVision:          requiresVision,
					hasTools:                hasTools,
					params:                  rejectionSamplingParams(parsed),
					servabilityComputed:     true,
					candidateCount:          candidateCount,
					capacityRejections:      capacityRejections,
					modelTooLargeRejections: modelTooLarge,
					bestTTFTMs:              float64(retryTTFT.Milliseconds()),
				})
				s.writeTTFTTooSlow(w, retryModel, publicModel, retryTTFT, ttftThreshold)
				return
			}
		}
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
	// Final cap on the body we'll seal. The read cap (parseInferencePrelude)
	// bounded the request as received, but rawBody has since been re-marshaled at
	// several points — alias resolution, allowlist/routing-field stripping,
	// reasoning_parser + max_tokens injection, Responses→chat lowering, and the
	// alias-capacity fallback above. The coordinator seals this body and sends it
	// as ONE WebSocket frame; a body over the cap produces a frame the provider
	// rejects by tearing down its session and cancelling every unrelated in-flight
	// request (see maxInferenceBodyBytes / CoordinatorClient.maxInboundMessageBytes).
	// This is the single point where rawBody is frozen into dispatchState, so the
	// check here covers every upstream mutation; an oversized request gets a clean
	// 413 instead of disconnecting a provider mid-flight. The reservation is held
	// at this point, so refund before returning.
	if len(rawBody) > maxInferenceBodyBytes {
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
			stream:                stream,
			estimatedPromptTokens: estimatedPromptTokens,
			requestedMaxTokens:    requestedMaxTokens,
			requiresVision:        requiresVision,
			hasTools:              hasTools,
			requestBodyBytes:      len(rawBody),
			params:                rejectionSamplingParams(parsed),
		})
		writeJSON(w, http.StatusRequestEntityTooLarge, errorResponse("invalid_request_error",
			fmt.Sprintf("request body exceeds the %d-byte limit", maxInferenceBodyBytes)))
		return
	}

	d := &dispatchState{
		s:                      s,
		w:                      w,
		r:                      r,
		model:                  model,
		publicModel:            publicModel,
		rawBody:                rawBody,
		consumerKey:            consumerKey,
		consumerLocation:       consumerLocation,
		reservedMicroUSD:       reservedMicroUSD,
		tokenAdmission:         tokenAdmission,
		serviceReservation:     serviceReservation,
		estimatedPromptTokens:  estimatedPromptTokens,
		requestedMaxTokens:     requestedMaxTokens,
		requiresVision:         requiresVision,
		hasTools:               hasTools,
		isResponsesAPI:         isResponsesAPI,
		stream:                 stream,
		policy:                 policy,
		allowedProviderSerials: allowedProviderSerials,
		cacheAffinityKey:       cacheAffinityKey,
		timing:                 timing,
		deadline:               deadline,
		speculativeAt:          time.Duration(float64(deadline) * speculativeTimerRatio),
		refundReservation:      refundReservation,
		// Track providers that failed during retry so we don't dispatch to them again.
		excludeProviders: make(map[string]struct{}),
	}
	d.run()
}

// handleStreamingResponseWithFirstChunk streams SSE chunks to the consumer.
// Any firstChunks (held preamble + first content chunk) are written in order
// before reading further chunks from the channel. This allows the dispatch
// loop to "peek" at chunks for retry decisions without losing them.
func (s *Server) handleStreamingResponseWithFirstChunk(w http.ResponseWriter, r *http.Request, pr *registry.PendingRequest, firstChunks []string) {
	if pr.IsResponsesAPI {
		s.handleResponsesStreamingResponseWithFirstChunk(w, r, pr, firstChunks)
		return
	}

	flusher, ok := w.(http.Flusher)
	if !ok {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "streaming not supported"))
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	// X-Request-ID is set by the logging middleware to the trace ID. The
	// internal pr.RequestID is the per-attempt provider job UUID and may
	// change across retries — exposing it as X-Request-ID would diverge
	// from the access log. Surface the provider job UUID under its own
	// header for callers who need to correlate to provider-side logs.
	w.Header().Set("X-Inference-Job-ID", pr.RequestID)
	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	// Detect Responses API format to skip appending chat-completions-style
	// termination events (SE signature chunk + [DONE]).
	sawResponsesAPI := false

	// The terminal include_usage chunk lacks the reasoning breakdown; we hold its
	// parsed object and re-emit it at stream end with the provider's authoritative
	// reasoning count (CompleteCh) spliced in — matching the non-streaming/Responses
	// paths. Held as a parsed map so it is decoded exactly once. Declared before the
	// first-chunk write because a zero-delta completion (empty/filtered output) can
	// make the include_usage frame the very first chunk.
	var pendingUsage map[string]any

	// The chunk carrying the terminal finish_reason is held the same way: the
	// provider engine reports "stop" even when generation hit the max-tokens
	// bound, so the coordinator re-derives "length" from the authoritative
	// token counts (CompleteCh) before forwarding it.
	var pendingFinish map[string]any

	// Write the chunks that were already consumed during dispatch (held
	// preamble first, then the committing content chunk), each through the
	// same per-chunk special-casing the relay loop below applies.
	for _, firstChunk := range firstChunks {
		if firstChunk == "" || isSSEDoneChunk(firstChunk) {
			continue
		}
		if isResponsesAPIEventChunk(firstChunk) {
			sawResponsesAPI = true
		}
		// A usage-only first chunk (no content/reasoning deltas streamed before it)
		// is still terminal usage — hold it so the reasoning breakdown is spliced in
		// at stream end instead of being emitted raw without reasoning_tokens.
		if obj, isUsage := parseUsageOnlyStreamChunk(firstChunk); !sawResponsesAPI && isUsage {
			pendingUsage = obj
		} else if obj, isFinish := parseFinishStreamChunk(normalizeSSEChunk(firstChunk)); !sawResponsesAPI && isFinish {
			pendingFinish = obj
		} else {
			if !sawResponsesAPI {
				firstChunk = normalizeSSEChunk(firstChunk)
			}
			firstChunk = rewriteChunkModel(firstChunk, pr)
			fmt.Fprintf(w, "%s\n\n", firstChunk)
			flusher.Flush()
		}
	}

	// Use a timer that resets on each chunk so long-running generations
	// (e.g. chain-of-thought models) don't hit a global timeout.
	timer := time.NewTimer(inferenceTimeout)
	defer timer.Stop()

	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if !ok {
				select {
				case errMsg, ok := <-pr.ErrorCh:
					if ok && errMsg.Error != "" {
						s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
						s.noteInferenceError(pr.ProviderID, pr, errMsg.StatusCode)
						s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_error"})
						errData, _ := json.Marshal(map[string]any{
							"error": map[string]any{
								"message": errMsg.Error,
								"type":    "provider_error",
							},
						})
						fmt.Fprintf(w, "data: %s\n\n", errData)
						flusher.Flush()
						return
					}
				default:
				}
				if s.refundReservedBalance(pr, "provider_incomplete:"+pr.RequestID) {
					s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_incomplete"})
					fmt.Fprintf(w, "data: {\"error\":{\"message\":\"provider ended without completion\",\"type\":\"provider_error\"}}\n\n")
					flusher.Flush()
					return
				}
				// Channel closed — inference complete.
				s.noteInferenceSuccess(pr)
				// For Responses API streams, the provider already sent
				// "response.completed" as the terminal event. Adding
				// extra chunks would break SDK parsers.
				if !sawResponsesAPI {
					// Emit the held finish/usage chunks with the authoritative token
					// counts (CompleteCh) spliced in: the finish chunk gets its
					// finish_reason corrected to "length" when generation hit the
					// max-tokens bound, and the usage chunk gets the reasoning
					// breakdown. This select runs once, at stream end: the provider's
					// inferenceComplete (which populates CompleteCh) is what ends the
					// stream, so it is effectively already buffered — the timeout is a
					// fallback, not a hot-path wait.
					var usage protocol.UsageInfo
					if pendingUsage != nil || pendingFinish != nil {
						select {
						case u, uok := <-pr.CompleteCh:
							if uok {
								usage = u
							}
						case <-time.After(2 * time.Second):
						case <-r.Context().Done():
						}
					}
					if pendingFinish != nil {
						if out := finalizeFinishChunk(pendingFinish, usage, pr); out != "" {
							fmt.Fprintf(w, "%s\n\n", out)
							flusher.Flush()
						}
					}
					if pendingUsage != nil {
						// Ride the SE signature on the held usage chunk (a complete,
						// well-formed chat.completion.chunk) instead of emitting a
						// separate bare event that strict SDK parsers reject.
						if pr.SESignature != "" {
							pendingUsage["se_signature"] = pr.SESignature
							pendingUsage["response_hash"] = pr.ResponseHash
						}
						if out := finalizeUsageChunk(pendingUsage, usage, pr); out != "" {
							fmt.Fprintf(w, "%s\n\n", out)
							flusher.Flush()
						}
					} else if pr.SESignature != "" {
						// No held usage chunk to ride on: emit the signature as a
						// fully-shaped chat.completion.chunk (id/object/created/model/
						// choices) so strict decoders parse it; the extra fields are
						// additive. It precedes the single [DONE] below.
						sigEvent, _ := json.Marshal(map[string]any{
							"id":            "chatcmpl-" + pr.RequestID,
							"object":        "chat.completion.chunk",
							"created":       time.Now().Unix(),
							"model":         consumerModel(pr),
							"choices":       []any{},
							"se_signature":  pr.SESignature,
							"response_hash": pr.ResponseHash,
						})
						fmt.Fprintf(w, "data: %s\n\n", sigEvent)
						flusher.Flush()
					}
					// Exactly one terminator, after every coordinator-appended event.
					fmt.Fprint(w, "data: [DONE]\n\n")
					flusher.Flush()
				}
				return
			}
			// Every chunk is a liveness signal — re-arm the idle timeout up front,
			// before deciding whether to forward or hold it, so holding the terminal
			// usage chunk still resets the window that bounds the wait for the
			// provider's inference_complete (which closes ChunkCh after billing).
			// One reset covers both the forward and hold paths.
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			timer.Reset(inferenceTimeout)

			if !sawResponsesAPI {
				if isResponsesAPIEventChunk(chunk) {
					sawResponsesAPI = true
				}
			}
			// Swallow the provider's own "data: [DONE]" terminator. The
			// coordinator appends terminal events of its own (held usage with
			// the reasoning breakdown, SE signature) and then emits exactly ONE
			// [DONE] — forwarding the provider's produced a stream shaped
			// `...usage, [DONE], signature, [DONE]`, and third-party SDKs treat
			// the first [DONE] as final (MacPaw/OpenAI then chokes parsing the
			// signature event).
			if !sawResponsesAPI && isSSEDoneChunk(chunk) {
				continue
			}
			// Hold the terminal usage chunk (chat completions only) so we can splice
			// in the reasoning breakdown at stream end; forwarding it inline would
			// emit it without reasoning_tokens.
			if !sawResponsesAPI {
				if obj, isUsage := parseUsageOnlyStreamChunk(chunk); isUsage {
					pendingUsage = obj
					continue
				}
			}
			if !sawResponsesAPI {
				chunk = normalizeSSEChunk(chunk)
				// Hold the chunk carrying the terminal finish_reason so it can be
				// corrected to "length" against the authoritative token counts at
				// stream end (the provider engine always reports "stop").
				if obj, isFinish := parseFinishStreamChunk(chunk); isFinish {
					pendingFinish = obj
					continue
				}
			}
			chunk = rewriteChunkModel(chunk, pr)
			fmt.Fprintf(w, "%s\n\n", chunk)
			flusher.Flush()

		case errMsg, ok := <-pr.ErrorCh:
			if !ok {
				continue
			}
			s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
			s.noteInferenceError(pr.ProviderID, pr, errMsg.StatusCode)
			s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_error"})
			errData, _ := json.Marshal(map[string]any{
				"error": map[string]any{
					"message": errMsg.Error,
					"type":    "provider_error",
				},
			})
			fmt.Fprintf(w, "data: %s\n\n", errData)
			flusher.Flush()
			return

		case <-timer.C:
			s.refundReservedBalance(pr, "provider_timeout:"+pr.RequestID)
			s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:timeout"})
			fmt.Fprintf(w, "data: {\"error\":{\"message\":\"request timed out\",\"type\":\"timeout\"}}\n\n")
			flusher.Flush()
			return

		case <-r.Context().Done():
			return
		}
	}
}

func (s *Server) handleResponsesStreamingResponseWithFirstChunk(w http.ResponseWriter, r *http.Request, pr *registry.PendingRequest, firstChunks []string) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "streaming not supported"))
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Inference-Job-ID", pr.RequestID)
	w.WriteHeader(http.StatusOK)

	responseID := "resp_" + strings.ReplaceAll(pr.RequestID, "-", "")
	createdAt := time.Now().Unix()
	emitter := newResponsesStreamEmitter(w, flusher, pr, responseID, createdAt)
	emitter.start()

	for _, firstChunk := range firstChunks {
		if firstChunk != "" {
			emitter.handleChunk(firstChunk)
		}
	}

	timer := time.NewTimer(inferenceTimeout)
	defer timer.Stop()

	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if !ok {
				var usage protocol.UsageInfo
				completed := false
				select {
				case u, ok := <-pr.CompleteCh:
					if ok {
						usage = u
						completed = true
					}
				case <-time.After(2 * time.Second):
				}
				if !completed && s.refundReservedBalance(pr, "provider_incomplete:"+pr.RequestID) {
					s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_incomplete"})
					emitter.emitError("provider_error", "provider ended without completion")
					return
				}
				s.noteInferenceSuccess(pr)
				emitter.finish(usage)
				return
			}
			emitter.handleChunk(chunk)
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			timer.Reset(inferenceTimeout)

		case errMsg, ok := <-pr.ErrorCh:
			if !ok {
				continue
			}
			s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
			s.noteInferenceError(pr.ProviderID, pr, errMsg.StatusCode)
			s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_error"})
			emitter.emitError("provider_error", errMsg.Error)
			return

		case <-timer.C:
			s.refundReservedBalance(pr, "provider_timeout:"+pr.RequestID)
			s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:timeout"})
			emitter.emitError("timeout", "request timed out")
			return

		case <-r.Context().Done():
			return
		}
	}
}

// handleNonStreamingResponseWithFirstChunk collects all chunks from the
// provider and assembles them into a single OpenAI-compatible JSON response.
// Any firstChunks (held preamble + first content chunk consumed during
// dispatch) seed the collected chunks in order.
func (s *Server) handleNonStreamingResponseWithFirstChunk(w http.ResponseWriter, r *http.Request, pr *registry.PendingRequest, firstChunks []string) {
	ctx, cancel := context.WithTimeout(r.Context(), inferenceTimeout)
	defer cancel()

	var chunks []string
	for _, firstChunk := range firstChunks {
		if firstChunk != "" {
			chunks = append(chunks, firstChunk)
		}
	}

	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if !ok {
				select {
				case errMsg, ok := <-pr.ErrorCh:
					if ok && errMsg.Error != "" {
						s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
						s.noteInferenceError(pr.ProviderID, pr, errMsg.StatusCode)
						statusCode := errMsg.StatusCode
						if statusCode == 0 {
							statusCode = http.StatusBadGateway
						}
						writeJSON(w, statusCode, errorResponse("provider_error", errMsg.Error))
						return
					}
				default:
				}
				// The provider forwards the raw backend response as a single
				// chunk. Detect complete responses (object=chat.completion
				// or object=response) and pass through directly — this is
				// format-agnostic and works for chat completions, Responses
				// API, or any future endpoint without parsing.
				if len(chunks) == 1 {
					raw := strings.TrimPrefix(chunks[0], "data: ")
					var obj map[string]any
					if err := json.Unmarshal([]byte(raw), &obj); err == nil {
						objType, _ := obj["object"].(string)
						// Complete responses have object=chat.completion or
						// object=response. Delta chunks have object=chat.completion.chunk.
						if objType == "chat.completion" || objType == "response" {
							var completeUsage protocol.UsageInfo
							select {
							case u, ok := <-pr.CompleteCh:
								if !ok {
									s.refundReservedBalance(pr, "provider_incomplete:"+pr.RequestID)
									writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "provider ended without completion"))
									return
								}
								completeUsage = u
							case <-ctx.Done():
								s.refundReservedBalance(pr, "provider_timeout:"+pr.RequestID)
								writeJSON(w, http.StatusGatewayTimeout, errorResponse("timeout", "timed out waiting for usage info"))
								return
							}
							if objType == "chat.completion" {
								normalizeCompleteChatResponse(obj, consumerModel(pr))
								// The provider engine reports "stop" even when generation
								// hit the max-tokens bound — correct it from the
								// authoritative token counts.
								rewriteRawFinishReason(obj, completeUsage, pr.RequestedMaxTokens)
								// Keep the passthrough path consistent with the
								// SSE-reconstruction path: surface the provider's
								// accurate reasoning-token count if its raw usage
								// object didn't already carry one.
								injectReasoningDetailIntoRawUsage(obj, completeUsage)
								if pr.IsResponsesAPI {
									var chatResp types.ChatCompletionResponse
									b, err := json.Marshal(obj)
									if err != nil {
										log.Printf("WARN: failed to marshal chat response for Responses API conversion: %v", err)
										writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "invalid provider response"))
										return
									}
									if err := json.Unmarshal(b, &chatResp); err != nil {
										log.Printf("WARN: failed to unmarshal chat response into typed struct: %v", err)
										writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "invalid provider response"))
										return
									}
									respObj := chatCompletionToResponses(chatResp, consumerModel(pr), pr.SESignature, pr.ResponseHash)
									s.noteInferenceSuccess(pr)
									writeJSON(w, http.StatusOK, respObj)
									return
								}
							} else {
								// Native passthrough (object=="response"): the provider
								// echoed the concrete build id; rewrite it to the public
								// alias so the consumer never sees the quant/build.
								if pr.PublicModel != "" {
									obj["model"] = consumerModel(pr)
								}
							}
							if pr.SESignature != "" {
								obj["se_signature"] = pr.SESignature
								obj["response_hash"] = pr.ResponseHash
							}
							s.noteInferenceSuccess(pr)
							writeJSON(w, http.StatusOK, obj)
							return
						}
					}
				}

				// Fallback: SSE delta chunks — reconstruct into response.
				msg := extractMessage(chunks)
				select {
				case usage, ok := <-pr.CompleteCh:
					if !ok {
						s.refundReservedBalance(pr, "provider_incomplete:"+pr.RequestID)
						writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "provider ended without completion"))
						return
					}
					var resp any
					if pr.IsResponsesAPI {
						resp = buildResponsesResponse(pr.RequestID, consumerModel(pr), msg, usage, pr.RequestedMaxTokens, pr.SESignature, pr.ResponseHash)
					} else {
						resp = buildNonStreamingResponse(pr.RequestID, consumerModel(pr), msg, usage, pr.RequestedMaxTokens, pr.SESignature, pr.ResponseHash)
					}
					s.noteInferenceSuccess(pr)
					writeJSON(w, http.StatusOK, resp)
				case <-ctx.Done():
					s.refundReservedBalance(pr, "provider_timeout:"+pr.RequestID)
					writeJSON(w, http.StatusGatewayTimeout, errorResponse("timeout", "timed out waiting for usage info"))
				}
				return
			}
			chunks = append(chunks, chunk)

		case errMsg, ok := <-pr.ErrorCh:
			if !ok {
				continue
			}
			s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
			s.noteInferenceError(pr.ProviderID, pr, errMsg.StatusCode)
			statusCode := errMsg.StatusCode
			if statusCode == 0 {
				statusCode = http.StatusBadGateway
			}
			writeJSON(w, statusCode, errorResponse("provider_error", errMsg.Error))
			return

		case <-ctx.Done():
			s.refundReservedBalance(pr, "provider_timeout:"+pr.RequestID)
			writeJSON(w, http.StatusGatewayTimeout, errorResponse("timeout", "request timed out"))
			return
		}
	}
}
