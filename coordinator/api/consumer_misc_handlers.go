package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
	"nhooyr.io/websocket"
)

// handleHealth handles GET /health.
// Returns the coordinator's status and the number of connected providers.
// This endpoint does not require authentication.
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, types.HealthResponse{
		Status:      "ok",
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
	const cacheKey = "api_version:v1"
	if cached, ok := s.readCache.Get(cacheKey); ok {
		writeCachedJSON(w, cached)
		return
	}

	var resp types.VersionResponse
	// Try release table first.
	if release := s.store.GetLatestRelease("macos-arm64"); release != nil {
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
	s.readCache.Set(cacheKey, body, time.Minute)
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

// writeJSON serializes v as JSON and writes it to the response with the
// given HTTP status code. Sets Content-Type to application/json.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

// handleCompletions handles POST /v1/completions.
// Proxies OpenAI-compatible text completions to the provider's vllm-mlx server.
func (s *Server) handleCompletions(w http.ResponseWriter, r *http.Request) {
	s.handleGenericInference(w, r, "/v1/completions")
}

// handleAnthropicMessages handles POST /v1/messages.
// Proxies Anthropic-compatible messages API to the provider's vllm-mlx server.
func (s *Server) handleAnthropicMessages(w http.ResponseWriter, r *http.Request) {
	s.handleGenericInference(w, r, "/v1/messages")
}

// handleGenericInference is the shared dispatch for completions and Anthropic endpoints.
// It reads the raw request body, extracts model/stream, sets the endpoint field,
// and reuses the same E2E encryption + provider routing as chat completions.
func (s *Server) handleGenericInference(w http.ResponseWriter, r *http.Request, endpoint string) {
	// Shared prelude: read body, normalize tool schemas (Anthropic /v1/messages
	// bodies carry a top-level "tools" array too; the provider body is rebuilt
	// from parsed below, so normalizing before the unmarshal covers it), parse,
	// require a model, enforce the per-key model allowlist.
	prelude, ok := s.parseInferencePrelude(w, r)
	if !ok {
		return
	}
	rawBody := prelude.rawBody
	parsed := prelude.parsed
	model := prelude.model

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
	if hasProviderAllowlist {
		stripProviderRoutingFields(parsed)
	}

	// "Use my own machine, for free" opt-in (see handleChatCompletions).
	policy := s.resolveSelfRoutePolicy(r)

	// Resolve a public alias to a concrete build id, constraint-aware (after
	// allowlist/self-route are known). resolveRequestedModel rewrites
	// parsed["model"] to the build; this handler builds the provider body fresh
	// from `parsed` (inferenceBody below), so rawBody isn't threaded here.
	buildModel, publicModel, _, ok := s.resolveRequestedModel(parsed, rawBody, model, allowedProviderSerials, policy)
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
	model = buildModel
	cacheAffinityKey := requestCacheAffinityKey(parsed)

	if !s.registry.IsModelInCatalog(model) {
		s.recordRejection(rejectionInfo{
			r:               r,
			stage:           "model_resolution",
			reasonCode:      "model_not_found",
			httpStatus:      http.StatusNotFound,
			keyID:           keyIDFromContext(r.Context()),
			consumerKeyHash: store.HashKey(consumerKeyFromContext(r.Context())),
			requestedModel:  publicModel,
			resolvedModel:   model,
			params:          rejectionSamplingParams(parsed),
		})
		writeJSON(w, http.StatusNotFound, errorResponse("model_not_found",
			fmt.Sprintf("model %q is not available — see /v1/models for supported models", publicModel), withParam("model")))
		return
	}

	// Shared media/tools fail-fast (see visionToolsFailFast). Completions and
	// Anthropic bodies share the top-level "tools" field; neither has the
	// Responses-API media surface, so rejectResponsesMedia is false here.
	requiresVision := detectMediaRequirement(parsed)
	hasTools := requestHasTools(parsed)
	if s.visionToolsFailFast(w, model, publicModel, requiresVision, hasTools,
		false, policy, allowedProviderSerials) {
		return
	}

	// Completions and Anthropic messages both use the max_tokens field (never
	// max_output_tokens, which is Responses API only). Inject a default if
	// unset so the pre-flight reservation bounds the generation.
	genericMaxOutput := defaultMaxOutputTokens
	if rec, err := s.store.GetModelRegistryRecord(model); err == nil && rec.MaxOutputLength > 0 {
		genericMaxOutput = rec.MaxOutputLength
	}
	ensureMaxTokensBound(parsed, false, genericMaxOutput)

	stream, _ := parsed["stream"].(bool)
	estimatedPromptTokens := estimatePromptTokens(parsed)
	billingPromptTokens := estimateBillingPromptTokens(parsed)
	requestedMaxTokens := estimateRequestedMaxTokens(parsed)
	genericDeadline := ttftDeadline(estimatedPromptTokens)

	// Inject the endpoint so the provider knows which local path to forward to.
	parsed["endpoint"] = endpoint

	// Per-account token rate limiting (ITPM/OTPM), before the reservation.
	tokenAdmission, ok := s.applyTokenRateLimitWithAdmission(w, r, estimatedPromptTokens, requestedMaxTokens)
	if !ok {
		return
	}

	// Pre-flight balance reservation — same worst-case-cost reservation as
	// handleChatCompletions, using the byte-length upper bound for prompt
	// tokens so the reservation always covers actual cost.
	consumerKey := consumerKeyFromContext(r.Context())
	consumerLocation := s.requestLocation(r)
	var reservedMicroUSD int64
	serviceReservation := false
	// Self-route is free: skip the reservation and per-key spend cap.
	if s.billing != nil && !policy.enabled {
		reservedMicroUSD = s.reservationCost(model, billingPromptTokens, requestedMaxTokens)
		// Per-key spend cap (phase 1) — checked before the reservation.
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
	refundReservation := func() {
		if reservedMicroUSD > 0 {
			s.releaseInitialReservation(consumerKey, model, reservedMicroUSD, serviceReservation)
		}
	}

	// Self-route pre-flight (precise errors, no paid fallback); otherwise the
	// fleet-wide capacity 429 (same logic as handleChatCompletions).
	if policy.enabled {
		if s.selfRouteUnavailable(w, r, policy.ownerAccountID, model) {
			refundReservation()
			return
		}
	} else if policy.prefer {
		// Prefer mode skips the public fleet pre-flight (no owner-trust
		// relaxation there); owned-first dispatch + paid fallback + queue gate it.
	} else {
		candidateCount, capacityRejections, modelTooLarge, bestTTFT, hasTTFT := s.registry.QuickCapacityCheckWithTTFTForRequest(model, estimatedPromptTokens, requestedMaxTokens, registry.RequestTraits{HasTools: hasTools}, requiresVision, allowedProviderSerials...)
		if candidateCount == 0 && capacityRejections > 0 {
			if fallbackModel, fallbackCandidates, fallbackRejections, fallbackTooLarge, fallbackTTFT, fallbackHasTTFT, switched := s.maybeFallbackAliasCapacity(parsed, publicModel, model, estimatedPromptTokens, requestedMaxTokens, registry.RequestTraits{HasTools: hasTools}, requiresVision, allowedProviderSerials); switched {
				model = fallbackModel
				candidateCount, capacityRejections, modelTooLarge = fallbackCandidates, fallbackRejections, fallbackTooLarge
				bestTTFT, hasTTFT = fallbackTTFT, fallbackHasTTFT
			}
		}
		if candidateCount == 0 && capacityRejections == 0 && modelTooLarge > 0 {
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
			// Queue-before-shed (default on): all providers for this model are at
			// capacity right now. Fall through to the dispatch+queue path so a slot
			// freeing — or a cold load completing — within the queue window serves
			// it; the queue path still 429s on a full queue or wait timeout.
			if s.queueBeforeShedEnabled() {
				s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:capacity_queue_spill"})
			} else {
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
			// No structurally-eligible provider right now (offline, trait-gated,
			// or shape-cooled by the inference-error breaker).
			//
			// Routing v2 W3 cold-dispatch (default on): if an idle on-disk provider
			// could be warmed to serve this model (and would pass admission for
			// these traits), spill into the queue instead of 503'ing — the enqueue
			// path kicks the model-swap machinery and the queued request drains
			// onto the provider once the cold load completes. Feed the autoscaler
			// the demand regardless of outcome.
			s.registry.RecordWarmPoolCapacityReject(model)
			s.triggerWarmPool()
			if s.coldDispatchEnabled() && s.coldSpillAvailable(model, registry.RequestTraits{HasTools: hasTools}, requiresVision, allowedProviderSerials) {
				s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:cold_dispatch_spill"})
				// Fall through to dispatch+queue; reservation kept.
			} else {
				// Queueing cannot help — fail fast with a retryable 503 instead of
				// a 120s queue. Mirrors the chat-completions preflight.
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
		ttftThreshold := genericDeadline
		if ttftTooSlow(bestTTFT, hasTTFT, ttftThreshold) {
			if !s.ttftHardReject {
				// Soft TTFT gate (default): serve the best-available provider
				// (MaxTTFTMs is 0 in soft mode — P1 fix); do not divert to an older
				// alias build (P2 fix). Feed the autoscaler a near-miss to grow
				// warm capacity for this model.
				s.registry.RecordWarmPoolTTFTMiss(model, ttftThreshold)
				s.triggerWarmPool()
				s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:ttft_soft_served"})
			} else if fallbackModel, _, _, _, fallbackTTFT, fallbackHasTTFT, switched := s.maybeFallbackAliasTTFT(parsed, publicModel, model, estimatedPromptTokens, requestedMaxTokens, ttftThreshold, registry.RequestTraits{HasTools: hasTools}, requiresVision, allowedProviderSerials); switched {
				model = fallbackModel
			} else {
				// Hard TTFT gate, no faster alias: 429 + Retry-After, and feed the
				// autoscaler a TTFT-miss so warm capacity grows.
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

	requestID := uuid.New().String()
	pr := &registry.PendingRequest{
		RequestID:              requestID,
		Model:                  model,
		PublicModel:            publicModel,
		ConsumerKey:            consumerKey,
		KeyID:                  keyIDFromContext(r.Context()),
		KeyLimitMicroUSD:       keyLimitMicroFromContext(r.Context()),
		KeyLimitReset:          keyLimitResetFromContext(r.Context()),
		ConsumerLocation:       consumerLocation,
		AllowedProviderSerials: allowedProviderSerials,
		SelfRouteOnly:          policy.enabled,
		PreferOwner:            policy.prefer,
		OwnerAccountID:         policy.ownerAccountID,
		FreeSelfRoute:          policy.enabled,
		EstimatedPromptTokens:  estimatedPromptTokens,
		RequiresVision:         requiresVision,
		CacheAffinityKey:       cacheAffinityKey,
		// Single-attempt path: no retry loop, so no AvoidVersion to thread.
		Traits:               registry.RequestTraits{HasTools: hasTools},
		RequestedMaxTokens:   requestedMaxTokens,
		TokenAdmission:       tokenAdmission,
		ReservedMicroUSD:     reservedMicroUSD,
		BaseReservedMicroUSD: reservedMicroUSD,
		ServiceReservation:   serviceReservation,
		AcceptedCh:           make(chan struct{}, 1),
		ChunkCh:              make(chan string, chunkBufferSize),
		CompleteCh:           make(chan protocol.UsageInfo, 1),
		ErrorCh:              make(chan protocol.InferenceErrorMessage, 1),
	}

	// Public inference routes (not self-route / prefer-owner) enforce the
	// OpenRouter TTFT ceiling inside the scheduler. This makes the preflight
	// check authoritative: the router cannot select a provider whose estimated
	// TTFT is above the threshold.
	// Routing v2 (P1 fix): enforce the TTFT ceiling only in HARD mode; soft mode
	// leaves MaxTTFTMs 0 so dispatch serves the best-available provider.
	if !policy.enabled && !policy.prefer && s.ttftHardReject {
		pr.MaxTTFTMs = float64(genericDeadline.Milliseconds())
	}
	// Routing v2 W2: soft per-request decode floor (0 = off).
	pr.MinDecodeTPS = s.minDecodeTPS

	// refundExtra credits back the provider-specific surcharge that
	// reserveAdditionalForProvider may have added on top of the base
	// reservation. Without this, failing after the extra charge leaks
	// the difference between pr.ReservedMicroUSD and the original
	// reservedMicroUSD.
	refundExtra := func() {
		extra := pr.ReservedMicroUSD - reservedMicroUSD
		if extra > 0 {
			start := time.Now()
			_ = s.store.Credit(consumerKey, extra, store.LedgerRefund, "reservation_extra_refund:"+requestID)
			s.ddIncr("billing.reservation_extra_refunds", []string{"model:" + model})
			s.ddHistogram("store.credit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:reservation_extra_refund"})
			pr.ReservedMicroUSD = reservedMicroUSD
		}
	}

	var provider *registry.Provider
	var decision registry.RoutingDecision
	var excludeProviders []string
	for attempt := 0; attempt < 3; attempt++ {
		provider, decision = s.registry.ReserveProviderEx(model, pr, excludeProviders...)
		if provider == nil {
			break
		}

		// Settles FREE when served by the caller's own machine: exclusive
		// self-route always, or a prefer request whose selected provider is owned
		// (settlement refunds to zero). Skip the payout warning + custom-price
		// top-up then (the top-up could otherwise 429 the free owned route).
		settlesFree := policy.enabled
		if !settlesFree && policy.prefer {
			provider.Mu().Lock()
			settlesFree = policy.ownerAccountID != "" && provider.AccountID == policy.ownerAccountID
			provider.Mu().Unlock()
		}

		if s.billing != nil && !settlesFree && !providerHasPayoutDestination(provider) {
			s.logger.Warn("provider missing payout destination, crediting to internal ledger",
				"provider_id", provider.ID)
		}

		// Custom pricing check — provider may charge more than the platform
		// rate. Skipped for free (owned) requests, which settle at zero cost.
		if s.billing != nil && !settlesFree {
			if _, err := s.reserveAdditionalForProvider(pr, provider); err != nil {
				provider.RemovePending(requestID)
				s.registry.SetProviderIdle(provider.ID)
				excludeProviders = append(excludeProviders, provider.ID)
				if !errors.Is(err, store.ErrInsufficientBalance) {
					s.logger.Error("provider reservation failed (DB error)",
						"request_id", requestID,
						"provider_id", provider.ID,
						"error", err,
					)
				}
				continue
			}
		}

		// Provider passed all checks.
		break
	}
	if provider == nil {
		// Providers are available but all exceed the TTFT ceiling. Fail fast
		// with a retryable 429 rather than queueing for a provider that would
		// miss the OpenRouter SLA target.
		if decision.TTFTRejections > 0 {
			bestTTFT := time.Duration(decision.BestTTFTMs * float64(time.Millisecond))
			refundReservation()
			s.writeTTFTTooSlow(w, model, publicModel, bestTTFT, genericDeadline)
			return
		}

		// No online provider can physically fit this model — queueing/retrying
		// can't help, so fast-fail with a clear, non-retryable error instead of
		// blocking for 120s then 503-ing. Mirrors the streaming dispatch path.
		if decision.CandidateCount == 0 && decision.CapacityRejections == 0 && decision.ModelTooLargeRejections > 0 {
			refundReservation()
			s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:model_too_large"})
			writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_unavailable",
				fmt.Sprintf("model %q is too large for any currently available provider", publicModel),
				withCode("model_unavailable")))
			return
		}
		queuedReq := &registry.QueuedRequest{
			RequestID:  requestID,
			Model:      model,
			Pending:    pr,
			ResponseCh: make(chan *registry.Provider, 1),
		}
		if err := s.registry.Queue().Enqueue(queuedReq); err != nil {
			retryAfter := s.estimateRetryAfter(model)
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
			refundReservation()
			s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:over_capacity"})
			if policy.enabled {
				writeJSON(w, http.StatusTooManyRequests, errorResponse("machine_busy",
					"your machine is at capacity — retry shortly", withCode("machine_busy")))
			} else {
				writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
					fmt.Sprintf("all providers for model %q are at capacity and queue is full", publicModel),
					withCode("rate_limit_exceeded")))
			}
			return
		}
		s.recordWarmPoolQueueState(model)
		// Routing v2 W3: the model now has queued demand — proactively warm a cold
		// provider for it (TriggerModelSwaps) instead of waiting for the next
		// heartbeat, so the queued request drains onto it sooner.
		s.kickColdDispatch(model)
		s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:queued"})
		provider, err = s.registry.Queue().WaitForProviderContext(r.Context(), queuedReq)
		if err != nil {
			if errors.Is(err, context.Canceled) {
				s.recordWarmPoolQueueState(model)
				refundReservation()
				return
			}
			retryAfter := s.estimateRetryAfter(model)
			s.registry.RecordWarmPoolQueueTimeout(model, time.Since(queuedReq.EnqueuedAt))
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
			refundReservation()
			if policy.enabled {
				writeJSON(w, http.StatusTooManyRequests, errorResponse("machine_busy",
					"your machine is at capacity (timed out waiting for a free slot) — retry shortly", withCode("machine_busy")))
			} else {
				writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
					fmt.Sprintf("all providers for model %q are at capacity (queue timeout)", publicModel),
					withCode("rate_limit_exceeded")))
			}
			return
		}
		s.recordWarmPoolQueueState(model)
		decision = queuedReq.Decision
	}
	s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:selected"})
	s.ddIncr("routing.provider_selected", []string{"provider_id:" + provider.ID, "model:" + model})
	s.ddHistogram("routing.cost_ms", decision.CostMs, []string{"model:" + model, "provider_id:" + provider.ID})
	if decision.EffectiveTPS > 0 {
		s.ddGauge("routing.effective_decode_tps", decision.EffectiveTPS, []string{"provider_id:" + provider.ID})
	}
	pendingCleanup := true
	cleanupPending := func() {
		if pendingCleanup {
			provider.RemovePending(requestID)
			s.registry.SetProviderIdle(provider.ID)
			pendingCleanup = false
		}
	}
	defer cleanupPending()
	// Settles FREE when served by the caller's own machine (exclusive self-route,
	// or a prefer request whose selected provider is owned — settlement refunds
	// to zero). Skip the payout warning + custom-price top-up then.
	settlesFreeDirect := policy.enabled
	if !settlesFreeDirect && policy.prefer {
		provider.Mu().Lock()
		settlesFreeDirect = policy.ownerAccountID != "" && provider.AccountID == policy.ownerAccountID
		provider.Mu().Unlock()
	}
	if s.billing != nil && !settlesFreeDirect && !providerHasPayoutDestination(provider) {
		s.logger.Warn("provider missing payout destination, crediting to internal ledger",
			"provider_id", provider.ID)
	}
	// Free (owned) requests settle at zero cost — no provider-price top-up.
	if s.billing != nil && !settlesFreeDirect {
		if _, err := s.reserveAdditionalForProvider(pr, provider); err != nil {
			cleanupPending()
			refundExtra()
			refundReservation()
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
					"your balance is too low for this provider price — add funds at /billing or lower max_tokens", withCode("insufficient_quota")))
			} else {
				s.logger.Error("provider reservation failed (DB error)", "consumer_key", consumerKey, "error", err)
				s.writeServiceUnavailable(w, model)
			}
			return
		}
	}

	inferenceBody, _ := marshalForwardBody(parsed)

	// Re-check the cap on the FINAL body we'll seal (the input cap bounded the
	// read; this body was re-marshaled after mutation). A body over the cap seals
	// into a frame the provider rejects by tearing down its session — return a
	// clean 413 instead (see maxInferenceBodyBytes). Billing is already reserved
	// at this point, so refund before returning.
	if len(inferenceBody) > maxInferenceBodyBytes {
		cleanupPending()
		refundExtra()
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
			requestBodyBytes:      len(inferenceBody),
			params:                rejectionSamplingParams(parsed),
		})
		writeJSON(w, http.StatusRequestEntityTooLarge, errorResponse("invalid_request_error",
			fmt.Sprintf("request body exceeds the %d-byte limit", maxInferenceBodyBytes)))
		return
	}

	if provider.PublicKey == "" {
		cleanupPending()
		refundExtra()
		refundReservation()
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("encryption_required",
			"no provider with E2E encryption available"))
		return
	}

	providerPubKey, err := e2e.ParsePublicKey(provider.PublicKey)
	if err != nil {
		cleanupPending()
		refundExtra()
		refundReservation()
		writeJSON(w, http.StatusInternalServerError, errorResponse("encryption_error", "provider public key invalid"))
		return
	}

	sessionKeys, err := e2e.GenerateSessionKeys()
	if err != nil {
		cleanupPending()
		refundExtra()
		refundReservation()
		writeJSON(w, http.StatusInternalServerError, errorResponse("encryption_error", "failed to generate session keys"))
		return
	}

	// Version-gated penalty strip for vision requests (Anthropic /v1/messages
	// carries image blocks); this handler seals separately from dispatchOneProvider.
	inferenceBody = bodyForProvider(inferenceBody, requiresVision, provider)
	encrypted, err := e2e.Encrypt(inferenceBody, providerPubKey, sessionKeys)
	if err != nil {
		cleanupPending()
		refundExtra()
		refundReservation()
		writeJSON(w, http.StatusInternalServerError, errorResponse("encryption_error", "failed to encrypt request"))
		return
	}

	wireMsg := map[string]any{
		"type":       protocol.TypeInferenceRequest,
		"request_id": requestID,
		"encrypted_body": map[string]string{
			"ephemeral_public_key": encrypted.EphemeralPublicKey,
			"ciphertext":           encrypted.Ciphertext,
		},
	}

	pr.SessionPrivKey = &sessionKeys.PrivateKey

	data, _ := json.Marshal(wireMsg)
	if err := provider.Conn.Write(r.Context(), websocket.MessageText, data); err != nil {
		cleanupPending()
		refundExtra()
		refundReservation()
		writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "failed to send request to provider"))
		return
	}
	pendingCleanup = false

	s.logger.Info("inference request dispatched",
		"request_id", requestID,
		"model", model,
		"provider_id", provider.ID,
		"endpoint", endpoint,
		"stream", stream,
	)

	// Dynamic TTFT deadline — wait for the first chunk or accepted signal
	// before committing. This mirrors the chat completions path but without
	// speculative dispatch (single attempt). If the provider misses the
	// TTFT deadline, the request fails instead of streaming forever.
	ttftTimer := time.NewTimer(genericDeadline)
	var firstChunk string
	committed := false
	accepted := false

	select {
	case <-pr.AcceptedCh:
		ttftTimer.Stop()
		accepted = true
	case chunk, ok := <-pr.ChunkCh:
		ttftTimer.Stop()
		if ok {
			firstChunk = chunk
			committed = true
		} else {
			select {
			case errMsg := <-pr.ErrorCh:
				provider.RemovePending(requestID)
				s.registry.SetProviderIdle(provider.ID)
				s.sendProviderCancel(provider, requestID)
				refundExtra()
				refundReservation()
				s.noteInferenceError(provider.ID, pr, errMsg.StatusCode)
				statusCode := errMsg.StatusCode
				if statusCode == 0 {
					statusCode = http.StatusBadGateway
				}
				writeJSON(w, statusCode, errorResponse("provider_error", errMsg.Error))
				return
			default:
				committed = true
			}
		}
	case errMsg := <-pr.ErrorCh:
		ttftTimer.Stop()
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.sendProviderCancel(provider, requestID)
		refundExtra()
		refundReservation()
		s.noteInferenceError(provider.ID, pr, errMsg.StatusCode)
		statusCode := errMsg.StatusCode
		if statusCode == 0 {
			statusCode = http.StatusBadGateway
		}
		writeJSON(w, statusCode, errorResponse("provider_error", errMsg.Error))
		return
	case <-ttftTimer.C:
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.sendProviderCancel(provider, requestID)
		refundExtra()
		refundReservation()
		s.ddIncr("inference.dispatches", []string{"status:timeout"})
		writeJSON(w, http.StatusGatewayTimeout, errorResponse("timeout", "provider did not respond within TTFT deadline"))
		return
	case <-r.Context().Done():
		ttftTimer.Stop()
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.sendProviderCancel(provider, requestID)
		refundExtra()
		refundReservation()
		return
	}

	// If provider accepted (model reload), wait for first chunk with extended deadline.
	if accepted && !committed {
		chunkTimer := time.NewTimer(inferenceTimeout)
		select {
		case chunk, ok := <-pr.ChunkCh:
			chunkTimer.Stop()
			if ok {
				firstChunk = chunk
				committed = true
			} else {
				select {
				case errMsg := <-pr.ErrorCh:
					provider.RemovePending(requestID)
					s.registry.SetProviderIdle(provider.ID)
					s.sendProviderCancel(provider, requestID)
					refundExtra()
					refundReservation()
					s.noteInferenceError(provider.ID, pr, errMsg.StatusCode)
					statusCode := errMsg.StatusCode
					if statusCode == 0 {
						statusCode = http.StatusBadGateway
					}
					writeJSON(w, statusCode, errorResponse("provider_error", errMsg.Error))
					return
				default:
					committed = true
				}
			}
		case errMsg := <-pr.ErrorCh:
			chunkTimer.Stop()
			provider.RemovePending(requestID)
			s.registry.SetProviderIdle(provider.ID)
			s.sendProviderCancel(provider, requestID)
			refundExtra()
			refundReservation()
			s.noteInferenceError(provider.ID, pr, errMsg.StatusCode)
			statusCode := errMsg.StatusCode
			if statusCode == 0 {
				statusCode = http.StatusBadGateway
			}
			writeJSON(w, statusCode, errorResponse("provider_error", errMsg.Error))
			return
		case <-chunkTimer.C:
			provider.RemovePending(requestID)
			s.registry.SetProviderIdle(provider.ID)
			s.sendProviderCancel(provider, requestID)
			refundExtra()
			refundReservation()
			// Accepted-then-silent is a provider-at-fault 504 — feed the
			// breaker (single-attempt path: no retry here, but repeated
			// stalls must still accumulate into the routing cooldown).
			s.noteInferenceError(provider.ID, pr, http.StatusGatewayTimeout)
			s.ddIncr("inference.dispatches", []string{"status:timeout"})
			writeJSON(w, http.StatusGatewayTimeout, errorResponse("timeout", "provider accepted but timed out before first chunk"))
			return
		case <-r.Context().Done():
			chunkTimer.Stop()
			provider.RemovePending(requestID)
			s.registry.SetProviderIdle(provider.ID)
			s.sendProviderCancel(provider, requestID)
			refundExtra()
			refundReservation()
			return
		}
	}

	if !committed {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.sendProviderCancel(provider, requestID)
		refundExtra()
		refundReservation()
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("provider_error", "failed to get first chunk from provider"))
		return
	}

	// Free the slot, stop the provider, and preserve billing on a mid-stream
	// disconnect (park-before-remove + post-terminal sweep; see the
	// chat-completions path for the full rationale).
	defer func() {
		if stale := provider.GetPending(requestID); stale != nil {
			s.holdForSettlement(stale)
		} else {
			refundPr := pr
			saferun.Go(s.logger, "api.postTerminalSweep", func() {
				s.refundReservedBalance(refundPr, "post_terminal_sweep:"+requestID)
			})
		}
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.sendProviderCancel(provider, requestID)
	}()

	var firstChunks []string
	if firstChunk != "" {
		firstChunks = []string{firstChunk}
	}
	if stream {
		s.handleStreamingResponseWithFirstChunk(w, r, pr, firstChunks)
	} else {
		s.handleNonStreamingResponseWithFirstChunk(w, r, pr, firstChunks)
	}
}

// errorDetailOpt carries optional fields for OpenAI-compatible error responses.
type errorDetailOpt struct {
	param string // e.g. "model", "max_tokens"
	code  string // e.g. "model_not_found", "insufficient_quota"
}

// errorResponse builds a standard OpenAI-compatible error response body.
// By default, code is inferred from errType. Callers can override code or
// set param via withParam / withCode helpers.
func errorResponse(errType, message string, opts ...errorDetailOpt) map[string]any {
	detail := map[string]any{
		"type":    errType,
		"message": message,
		"code":    errType, // default: code mirrors type
	}
	for _, o := range opts {
		if o.param != "" {
			detail["param"] = o.param
		}
		if o.code != "" {
			detail["code"] = o.code
		}
	}
	return map[string]any{
		"error": detail,
	}
}

// withParam returns an option that sets the "param" field on an error response.
func withParam(p string) errorDetailOpt { return errorDetailOpt{param: p} }

// withCode returns an option that overrides the "code" field on an error response.
func withCode(c string) errorDetailOpt { return errorDetailOpt{code: c} }
