package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
	"nhooyr.io/websocket"
)

const (
	// inferenceTimeout is the maximum time to wait between chunks (streaming)
	// or for the full response (non-streaming). For streaming, the deadline
	// resets on each received chunk so long-running generations don't time out.
	// 10 minutes allows 32k tokens at ~55 tok/s on slower hardware.
	inferenceTimeout = 600 * time.Second

	// chunkBufferSize is the channel buffer size for SSE chunks flowing from
	// the provider to the consumer. A larger buffer prevents dropped chunks
	// when the consumer reads slowly.
	chunkBufferSize = 256

	// maxDispatchAttempts is the maximum number of provider dispatch attempts
	// before returning an error to the consumer. The coordinator retries on
	// the same or a different provider when the first attempt fails (e.g.
	// backend crashed, model not loaded after idle shutdown).
	maxDispatchAttempts = 3

	// speculativeTimerRatio is the fraction of the TTFT deadline at which
	// the coordinator launches a speculative backup dispatch. The primary
	// provider gets this fraction of the deadline before the backup is
	// started, and then both race until one produces the first chunk.
	speculativeTimerRatio = 0.5

	// cancelWriteTimeout bounds how long a cancel write to the provider can
	// block. Using context.Background() unbounded here risks hanging the HTTP
	// handler goroutine when a WebSocket is half-dead.
	cancelWriteTimeout = 2 * time.Second
)

// ttftDeadline returns the TTFT budget for a request based on prompt size.
// Base: 5 seconds + 1ms per estimated input token. This meets the OpenRouter
// SLA of TTFT < 5s + 1ms/input_token.
func ttftDeadline(estimatedPromptTokens int) time.Duration {
	base := 5 * time.Second
	perToken := time.Duration(estimatedPromptTokens) * time.Millisecond
	return base + perToken
}

// sendProviderCancel sends a Cancel message for the given request to the
// provider with a bounded timeout so a half-dead WebSocket doesn't hang the
// caller. Errors are logged at debug level because a disconnect race is the
// expected case — the provider may already be gone.
func (s *Server) sendProviderCancel(provider *registry.Provider, requestID string) {
	if provider == nil || provider.Conn == nil {
		return
	}
	cancelMsg := protocol.CancelMessage{Type: protocol.TypeCancel, RequestID: requestID}
	cancelData, err := json.Marshal(cancelMsg)
	if err != nil {
		s.logger.Error("failed to marshal cancel message", "request_id", requestID, "error", err)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), cancelWriteTimeout)
	defer cancel()
	if err := provider.Conn.Write(ctx, websocket.MessageText, cancelData); err != nil {
		s.logger.Debug("failed to send cancel (provider may have disconnected)",
			"request_id", requestID, "error", err)
	}
}

// cancelDispatch cleans up a speculative dispatch participant that lost the
// race (or a failed/timed-out attempt): removes the pending request, marks the
// provider idle, sends a cancel over WebSocket so the provider stops generating
// tokens, and refunds this attempt's provider-specific reservation top-up.
//
// The top-up refund only runs if THIS call actually removed the pending request
// (RemovePending returned non-nil). If settlement (handleComplete) already
// claimed it via its own RemovePending, we must not also refund — that would
// double-credit the consumer.
func (s *Server) cancelDispatch(provider *registry.Provider, pr *registry.PendingRequest) {
	if provider == nil || pr == nil {
		return
	}
	removed := provider.RemovePending(pr.RequestID)
	s.registry.SetProviderIdle(provider.ID)
	s.sendProviderCancel(provider, pr.RequestID)
	if removed != nil {
		s.refundProviderExtra(pr)
	}
}

// dispatchOneProvider encrypts and sends an inference request to a single
// provider. It returns the pending request and provider on success, or an
// error string on failure. The excludeProviders set is updated on failure.
func (s *Server) dispatchOneProvider(
	r *http.Request,
	model string,
	rawBody []byte,
	consumerKey string,
	consumerLocation *store.ProviderLocation,
	reservedMicroUSD int64,
	estimatedPromptTokens int,
	requestedMaxTokens int,
	allowedProviderSerials []string,
	isResponsesAPI bool,
	timing *registry.RequestTiming,
	excludeProviders map[string]struct{},
) (
	provider *registry.Provider,
	pr *registry.PendingRequest,
	decision registry.RoutingDecision,
	lastErr string,
	lastErrCode int,
) {
	requestID := uuid.New().String()
	pr = &registry.PendingRequest{
		RequestID:              requestID,
		Model:                  model,
		ConsumerKey:            consumerKey,
		KeyID:                  keyIDFromContext(r.Context()),
		KeyLimitMicroUSD:       keyLimitMicroFromContext(r.Context()),
		KeyLimitReset:          keyLimitResetFromContext(r.Context()),
		ConsumerLocation:       consumerLocation,
		IsResponsesAPI:         isResponsesAPI,
		EstimatedPromptTokens:  estimatedPromptTokens,
		RequestedMaxTokens:     requestedMaxTokens,
		ReservedMicroUSD:       reservedMicroUSD,
		BaseReservedMicroUSD:   reservedMicroUSD,
		AllowedProviderSerials: allowedProviderSerials,
		AcceptedCh:             make(chan struct{}, 1),
		ChunkCh:                make(chan string, chunkBufferSize),
		CompleteCh:             make(chan protocol.UsageInfo, 1),
		ErrorCh:                make(chan protocol.InferenceErrorMessage, 1),
		Timing:                 timing,
	}

	excludeList := func() []string {
		ids := make([]string, 0, len(excludeProviders))
		for id := range excludeProviders {
			ids = append(ids, id)
		}
		return ids
	}

	provider, decision = s.registry.ReserveProviderEx(model, pr, excludeList()...)
	if provider == nil {
		return nil, nil, decision, "no provider available", http.StatusServiceUnavailable
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
	if pr.Timing != nil {
		pr.Timing.RoutedAt = time.Now()
	}

	if s.billing != nil && !providerHasPayoutDestination(provider) {
		s.logger.Warn("provider missing payout destination, crediting to internal ledger",
			"provider_id", provider.ID)
	}

	if s.billing != nil {
		_, err := s.reserveAdditionalForProvider(pr, provider)
		if err != nil {
			cleanupPending()
			excludeProviders[provider.ID] = struct{}{}
			if errors.Is(err, store.ErrInsufficientBalance) {
				return nil, nil, decision, "insufficient funds for provider price", http.StatusPaymentRequired
			}
			s.logger.Error("provider reservation failed (DB error)", "provider_id", provider.ID, "error", err)
			return nil, nil, decision, "service temporarily unavailable — please retry", http.StatusServiceUnavailable
		}
	}
	// refundExtra credits back the provider-specific surcharge that
	// reserveAdditionalForProvider may have added. The caller's
	// refundReservation only covers the base reservation.
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

	// E2E encryption
	if provider.PublicKey == "" {
		refundExtra()
		cleanupPending()
		excludeProviders[provider.ID] = struct{}{}
		return nil, nil, decision, "no provider with E2E encryption", http.StatusServiceUnavailable
	}

	providerPubKey, err := e2e.ParsePublicKey(provider.PublicKey)
	if err != nil {
		refundExtra()
		cleanupPending()
		excludeProviders[provider.ID] = struct{}{}
		return nil, nil, decision, "provider public key invalid", http.StatusServiceUnavailable
	}

	sessionKeys, err := e2e.GenerateSessionKeys()
	if err != nil {
		refundExtra()
		cleanupPending()
		return nil, nil, decision, "failed to generate session keys", http.StatusInternalServerError
	}

	encrypted, err := e2e.Encrypt(rawBody, providerPubKey, sessionKeys)
	if err != nil {
		refundExtra()
		cleanupPending()
		return nil, nil, decision, "failed to encrypt request", http.StatusInternalServerError
	}
	if pr.Timing != nil {
		pr.Timing.EncryptedAt = time.Now()
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
	// pr.ReservedMicroUSD was already set in the struct literal and may have
	// been increased by reserveAdditionalForProvider above. Don't overwrite.

	data, err := json.Marshal(wireMsg)
	if err != nil {
		refundExtra()
		cleanupPending()
		return nil, nil, decision, "failed to marshal request", http.StatusInternalServerError
	}
	if err := provider.Conn.Write(r.Context(), websocket.MessageText, data); err != nil {
		refundExtra()
		cleanupPending()
		excludeProviders[provider.ID] = struct{}{}
		return nil, nil, decision, "failed to send request to provider", http.StatusBadGateway
	}
	pendingCleanup = false
	pr.Timing.DispatchedAt = time.Now()

	return provider, pr, decision, "", 0
}

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

	// Read the raw request body so we can forward it as-is to the provider.
	// We only parse minimally to extract model/stream/messages for routing.
	rawBody, err := io.ReadAll(r.Body)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "failed to read request body"))
		return
	}

	var parsed map[string]any
	if err := json.Unmarshal(rawBody, &parsed); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}

	model, _ := parsed["model"].(string)
	if model == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "model is required", withParam("model")))
		return
	}

	// Per-key model allow-list enforcement (phase 3).
	if !s.keyModelAllowed(r.Context(), model) {
		writeJSON(w, http.StatusForbidden, errorResponse("model_not_allowed",
			fmt.Sprintf("this API key is not permitted to use model %q", model), withParam("model")))
		return
	}

	// Accept either chat completions format (messages) or Responses API
	// format (input). The provider's backend handles both natively.
	messages, _ := parsed["messages"].([]any)
	input := parsed["input"]
	if len(messages) == 0 && input == nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "messages or input is required"))
		return
	}

	allowedProviderSerials, hasProviderAllowlist, err := parseProviderSerialAllowlist(parsed)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", err.Error()))
		return
	}
	if hasProviderAllowlist && stripProviderRoutingFields(parsed) {
		rawBody, _ = json.Marshal(parsed)
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
				rawBody, _ = json.Marshal(parsed)
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
		rawBody, _ = json.Marshal(parsed)
	}

	stream, _ := parsed["stream"].(bool)
	estimatedPromptTokens := estimatePromptTokens(parsed)
	billingPromptTokens := estimateBillingPromptTokens(parsed)
	requestedMaxTokens := estimateRequestedMaxTokens(parsed)
	timing.ParsedAt = time.Now()

	if isResponsesAPI {
		providerParsed, err := responsesRequestToChatCompletions(parsed)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", err.Error()))
			return
		}
		rawBody, _ = json.Marshal(providerParsed)
	}

	// Per-account token rate limiting (ITPM/OTPM) — the industry-standard
	// token throttle alongside RPM. Charged upfront from the input estimate
	// and the bounded max_tokens (OpenAI-style). Runs before the balance
	// reservation so a throttled request never touches billing.
	if !s.applyTokenRateLimit(w, r, estimatedPromptTokens, requestedMaxTokens) {
		return
	}

	// Pre-flight balance reservation — atomically debit the worst-case cost
	// using the byte-length upper bound for prompt tokens (guaranteed >=
	// actual tokens for any BPE tokenizer) plus max_tokens we just bounded
	// the generation to. The post-inference charge refunds any unused
	// portion. The routing estimate (estimatedPromptTokens, len/4) is kept
	// separate so scheduler capacity checks aren't over-inflated.
	var reservedMicroUSD int64
	if s.billing != nil {
		consumerKey := consumerKeyFromContext(r.Context())
		reservedMicroUSD = s.reservationCost(model, billingPromptTokens, requestedMaxTokens)
		// Per-key spend cap (phase 1) — checked before the reservation so a
		// capped key never debits the account ledger.
		if msg, ok := s.checkKeySpendCap(r.Context(), reservedMicroUSD); !ok {
			writeJSON(w, http.StatusPaymentRequired, errorResponse("insufficient_quota", msg, withCode("insufficient_quota")))
			return
		}
		start := time.Now()
		if err := s.ledger.Charge(consumerKey, reservedMicroUSD, "reserve:"+consumerKey); err != nil {
			if errors.Is(err, store.ErrInsufficientBalance) {
				writeJSON(w, http.StatusPaymentRequired, errorResponse("insufficient_funds",
					"your balance is too low for this request — add funds at /billing or lower max_tokens", withCode("insufficient_quota")))
			} else {
				s.logger.Error("balance reservation failed (DB error)", "consumer_key", consumerKey, "error", err)
				writeJSON(w, http.StatusServiceUnavailable, errorResponse("service_unavailable",
					"service temporarily unavailable — please retry"))
			}
			return
		}
		s.ddHistogram("billing.reserved_micro_usd", float64(reservedMicroUSD), []string{"model:" + model})
		s.ddHistogram("store.debit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:reserve"})
	}
	timing.ReservedAt = time.Now()

	// Refund reservation on early errors (before inference starts).
	refundReservation := func() {
		if reservedMicroUSD > 0 {
			consumerKey := consumerKeyFromContext(r.Context())
			start := time.Now()
			_ = s.store.Credit(consumerKey, reservedMicroUSD, store.LedgerRefund, "reservation_refund")
			s.ddIncr("billing.reservation_refunds", []string{"model:" + model})
			s.ddHistogram("store.credit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:reservation_refund"})
		}
	}

	// Reject requests for models not in the catalog.
	if !s.registry.IsModelInCatalog(model) {
		refundReservation()
		writeJSON(w, http.StatusNotFound, errorResponse("model_not_found",
			fmt.Sprintf("model %q is not available — see /v1/models for supported models", model), withParam("model")))
		return
	}

	// Pre-flight capacity check: can ANY provider serve this model right now?
	// If not, return 429 immediately rather than queueing for up to 120s.
	// OpenRouter treats 429 as "rate limited" (no uptime penalty) vs 503
	// which counts as downtime. Fast 429s also preserve our TTFT metrics.
	candidateCount, capacityRejections := s.registry.QuickCapacityCheck(model, estimatedPromptTokens, requestedMaxTokens, allowedProviderSerials...)
	if candidateCount == 0 && capacityRejections > 0 {
		// Providers exist for this model but ALL are at capacity.
		retryAfter := s.estimateRetryAfter(model)
		w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
		refundReservation()
		s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:capacity_429"})
		writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
			fmt.Sprintf("all providers for model %q are at capacity — retry after %ds", model, retryAfter),
			withCode("rate_limit_exceeded")))
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
	var (
		provider    *registry.Provider
		pr          *registry.PendingRequest
		requestID   string
		firstChunk  string
		lastErr     string
		lastErrCode int
		committed   bool
	)

	consumerKey := consumerKeyFromContext(r.Context())
	consumerLocation := s.requestLocation(r)

	// Track providers that failed during retry so we don't dispatch to them again.
	excludeProviders := make(map[string]struct{})

	deadline := ttftDeadline(estimatedPromptTokens)
	speculativeAt := time.Duration(float64(deadline) * speculativeTimerRatio)

	for attempt := range maxDispatchAttempts {
		// Dispatch the primary provider.
		var dispatchErr string
		var dispatchErrCode int
		provider, pr, _, dispatchErr, dispatchErrCode = s.dispatchOneProvider(
			r, model, rawBody, consumerKey, consumerLocation, reservedMicroUSD,
			estimatedPromptTokens, requestedMaxTokens, allowedProviderSerials,
			isResponsesAPI, timing, excludeProviders,
		)
		if provider == nil {
			// dispatchOneProvider may have found a provider but rejected it
			// (payout destination missing, insufficient funds, encryption
			// missing). In that case it already added the provider to
			// excludeProviders. If there may be more providers to try,
			// continue to the next attempt.
			providerWasRejected := dispatchErr != "no provider available"
			if providerWasRejected {
				lastErr = dispatchErr
				lastErrCode = dispatchErrCode
				continue
			}

			// On retry attempts, don't queue — if the only available
			// providers already failed, waiting 120s for one of them
			// to come back won't help. Break and return the last error.
			// Don't overwrite lastErr/lastErrCode from the real provider
			// error — preserve the original status code.
			if attempt > 0 {
				if lastErr == "" {
					lastErr = dispatchErr
					lastErrCode = dispatchErrCode
				}
				break
			}
			// No idle provider — try queueing.
			requestID = uuid.New().String()
			queuePR := &registry.PendingRequest{
				RequestID:              requestID,
				Model:                  model,
				ConsumerKey:            consumerKey,
				KeyID:                  keyIDFromContext(r.Context()),
				KeyLimitMicroUSD:       keyLimitMicroFromContext(r.Context()),
				KeyLimitReset:          keyLimitResetFromContext(r.Context()),
				ConsumerLocation:       consumerLocation,
				IsResponsesAPI:         isResponsesAPI,
				EstimatedPromptTokens:  estimatedPromptTokens,
				RequestedMaxTokens:     requestedMaxTokens,
				ReservedMicroUSD:       reservedMicroUSD,
				BaseReservedMicroUSD:   reservedMicroUSD,
				AllowedProviderSerials: allowedProviderSerials,
				AcceptedCh:             make(chan struct{}, 1),
				ChunkCh:                make(chan string, chunkBufferSize),
				CompleteCh:             make(chan protocol.UsageInfo, 1),
				ErrorCh:                make(chan protocol.InferenceErrorMessage, 1),
				Timing:                 timing,
			}
			queuedReq := &registry.QueuedRequest{
				RequestID:  requestID,
				Model:      model,
				Pending:    queuePR,
				ResponseCh: make(chan *registry.Provider, 1),
			}
			queuePR.Timing.QueuedAt = time.Now()
			if err := s.registry.Queue().Enqueue(queuedReq); err != nil {
				s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:over_capacity"})
				retryAfter := s.estimateRetryAfter(model)
				w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
				refundReservation()
				writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
					fmt.Sprintf("all providers for model %q are at capacity and queue is full", model),
					withCode("rate_limit_exceeded")))
				return
			}
			s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:queued"})

			s.logger.Info("request queued, waiting for provider",
				"model", model,
				"attempt", attempt+1,
			)

			var err error
			provider, err = s.registry.Queue().WaitForProviderContext(r.Context(), queuedReq)
			if err != nil {
				if errors.Is(err, context.Canceled) {
					refundReservation()
					return
				}
				refundReservation()
				s.ddIncr("request_queue.timeout", []string{"model:" + model, "model_type:" + s.registry.ModelType(model)})
				retryAfter := s.estimateRetryAfter(model)
				w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
				writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
					fmt.Sprintf("all providers for model %q are at capacity (queue timeout)", model),
					withCode("rate_limit_exceeded")))
				return
			}
			// Queue assigned a provider; still need to dispatch.
			// Use the queue PR's channels.
			pr = queuePR
			requestID = pr.RequestID
			timing.RoutedAt = time.Now()

			// Log missing payout destination but don't skip — earnings
			// are credited to the provider's internal ledger and can be
			// withdrawn once they complete Stripe Connect onboarding.
			if s.billing != nil && !providerHasPayoutDestination(provider) {
				s.logger.Warn("queued provider missing payout destination, crediting to internal ledger",
					"request_id", requestID,
					"provider_id", provider.ID,
				)
			}

			// Custom pricing check — provider may charge more than the
			// platform rate. Reserve the additional amount now.
			if s.billing != nil {
				if _, err := s.reserveAdditionalForProvider(pr, provider); err != nil {
					provider.RemovePending(requestID)
					s.registry.SetProviderIdle(provider.ID)
					excludeProviders[provider.ID] = struct{}{}
					if errors.Is(err, store.ErrInsufficientBalance) {
						s.logger.Warn("queued provider pricing exceeds balance, skipping",
							"request_id", requestID,
							"provider_id", provider.ID,
							"error", err,
						)
						lastErr = "insufficient funds for provider price"
						lastErrCode = http.StatusPaymentRequired
					} else {
						s.logger.Error("queued provider reservation failed (DB error)",
							"request_id", requestID,
							"provider_id", provider.ID,
							"error", err,
						)
						lastErr = "service temporarily unavailable — please retry"
						lastErrCode = http.StatusServiceUnavailable
					}
					continue
				}
			}
			// Perform E2E encryption and send the request.
			if provider.PublicKey == "" {
				provider.RemovePending(requestID)
				s.registry.SetProviderIdle(provider.ID)
				s.refundProviderExtra(pr)
				excludeProviders[provider.ID] = struct{}{}
				lastErr = "no provider with E2E encryption"
				continue
			}
			providerPubKey, err := e2e.ParsePublicKey(provider.PublicKey)
			if err != nil {
				provider.RemovePending(requestID)
				s.registry.SetProviderIdle(provider.ID)
				s.refundProviderExtra(pr)
				excludeProviders[provider.ID] = struct{}{}
				lastErr = "provider public key invalid"
				continue
			}
			sessionKeys, err := e2e.GenerateSessionKeys()
			if err != nil {
				provider.RemovePending(requestID)
				s.registry.SetProviderIdle(provider.ID)
				s.refundProviderExtra(pr)
				lastErr = "failed to generate session keys"
				continue
			}
			encrypted, err := e2e.Encrypt(rawBody, providerPubKey, sessionKeys)
			if err != nil {
				provider.RemovePending(requestID)
				s.registry.SetProviderIdle(provider.ID)
				s.refundProviderExtra(pr)
				lastErr = "failed to encrypt request"
				continue
			}
			timing.EncryptedAt = time.Now()
			wireMsg := map[string]any{
				"type":       protocol.TypeInferenceRequest,
				"request_id": requestID,
				"encrypted_body": map[string]string{
					"ephemeral_public_key": encrypted.EphemeralPublicKey,
					"ciphertext":           encrypted.Ciphertext,
				},
			}
			pr.SessionPrivKey = &sessionKeys.PrivateKey
			// pr.ReservedMicroUSD was already set in the struct literal and may
			// have been increased by reserveAdditionalForProvider. Don't overwrite.
			data, _ := json.Marshal(wireMsg)
			if err := provider.Conn.Write(r.Context(), websocket.MessageText, data); err != nil {
				provider.RemovePending(requestID)
				s.registry.SetProviderIdle(provider.ID)
				s.refundProviderExtra(pr)
				excludeProviders[provider.ID] = struct{}{}
				lastErr = "failed to send request to provider"
				continue
			}
			pr.Timing.DispatchedAt = time.Now()
		}
		requestID = pr.RequestID
		if timing.RoutedAt.IsZero() {
			timing.RoutedAt = time.Now()
		}
		s.ddIncr("routing.decisions", []string{"model:" + model, "outcome:selected"})
		s.ddIncr("routing.provider_selected", []string{"provider_id:" + provider.ID, "model:" + model})

		s.logger.Info("inference request dispatched",
			"trace_id", requestIDFromContext(r.Context()),
			"request_id", requestID,
			"model", model,
			"provider_id", provider.ID,
			"stream", stream,
			"attempt", attempt+1,
		)

		s.logger.Info("dispatch_pool",
			"model", model,
			"ttft_deadline_ms", deadline.Milliseconds(),
			"speculative_at_ms", speculativeAt.Milliseconds(),
		)

		// ---- Speculative TTFT-aware first-chunk wait ----
		//
		// Phase 1: Wait for first chunk with speculative timer.
		// - If primary sends first chunk → commit.
		// - If primary sends accepted → extend to inferenceTimeout (model reload).
		// - If primary errors → retry immediately (sequential fallback).
		// - If speculative timer fires → dispatch backup and race.
		// - If full deadline expires → fail.

		speculativeTimer := time.NewTimer(speculativeAt)
		deadlineTimer := time.NewTimer(deadline)
		accepted := false

		select {
		case chunk, ok := <-pr.ChunkCh:
			speculativeTimer.Stop()
			deadlineTimer.Stop()
			if ok {
				firstChunk = chunk
				pr.Timing.FirstChunkAt = time.Now()
				committed = true
			} else {
				select {
				case errMsg := <-pr.ErrorCh:
					excludeProviders[provider.ID] = struct{}{}
					s.cancelDispatch(provider, pr)
					lastErr = errMsg.Error
					lastErrCode = errMsg.StatusCode
					provider = nil
					pr = nil
					continue
				default:
					committed = true
				}
			}

		case <-pr.AcceptedCh:
			speculativeTimer.Stop()
			deadlineTimer.Stop()
			accepted = true

		case errMsg := <-pr.ErrorCh:
			speculativeTimer.Stop()
			deadlineTimer.Stop()
			excludeProviders[provider.ID] = struct{}{}
			s.cancelDispatch(provider, pr)
			lastErr = errMsg.Error
			lastErrCode = errMsg.StatusCode
			s.logger.Warn("provider failed, retrying",
				"request_id", requestID,
				"provider_id", provider.ID,
				"attempt", attempt+1,
				"error", errMsg.Error,
			)
			s.emitRequest(r.Context(), protocol.SeverityWarn, requestID,
				"provider failed, retrying",
				map[string]any{
					"provider_id": provider.ID,
					"attempt":     attempt + 1,
					"reason":      "provider_error",
					"status_code": errMsg.StatusCode,
				})
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "retry"})
			}
			s.ddIncr("inference.dispatches", []string{"status:retry"})
			provider = nil
			pr = nil
			continue

		case <-speculativeTimer.C:
			deadlineTimer.Stop()
			// Primary is slow. Attempt speculative backup dispatch.
			s.ddIncr("inference.speculative_dispatch", []string{"model:" + model})

			backupExclude := make(map[string]struct{}, len(excludeProviders)+1)
			for id := range excludeProviders {
				backupExclude[id] = struct{}{}
			}
			backupExclude[provider.ID] = struct{}{}

			backupProvider, backupPR, _, _, _ := s.dispatchOneProvider(
				r, model, rawBody, consumerKey, consumerLocation, reservedMicroUSD,
				estimatedPromptTokens, requestedMaxTokens, allowedProviderSerials,
				isResponsesAPI, &registry.RequestTiming{ReceivedAt: timing.ReceivedAt},
				backupExclude,
			)

			if backupProvider == nil {
				// No backup available. Keep waiting for primary with remaining deadline.
				s.logger.Info("speculative_dispatch_no_backup",
					"request_id", requestID,
					"primary_provider", provider.ID,
				)
				remainingDeadline := time.NewTimer(deadline - speculativeAt)
				select {
				case chunk, ok := <-pr.ChunkCh:
					remainingDeadline.Stop()
					if ok {
						firstChunk = chunk
						pr.Timing.FirstChunkAt = time.Now()
						committed = true
					} else {
						select {
						case errMsg := <-pr.ErrorCh:
							excludeProviders[provider.ID] = struct{}{}
							s.cancelDispatch(provider, pr)
							lastErr = errMsg.Error
							lastErrCode = errMsg.StatusCode
							provider = nil
							pr = nil
							continue
						default:
							committed = true
						}
					}
				case <-pr.AcceptedCh:
					remainingDeadline.Stop()
					accepted = true
				case errMsg := <-pr.ErrorCh:
					remainingDeadline.Stop()
					excludeProviders[provider.ID] = struct{}{}
					s.cancelDispatch(provider, pr)
					lastErr = errMsg.Error
					lastErrCode = errMsg.StatusCode
					if s.metrics != nil {
						s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "retry"})
					}
					s.ddIncr("inference.dispatches", []string{"status:retry"})
					provider = nil
					pr = nil
					continue
				case <-remainingDeadline.C:
					excludeProviders[provider.ID] = struct{}{}
					s.cancelDispatch(provider, pr)
					lastErr = "timeout waiting for first response"
					lastErrCode = http.StatusGatewayTimeout
					s.logger.Warn("provider timeout (no backup), retrying",
						"request_id", requestID,
						"provider_id", provider.ID,
						"attempt", attempt+1,
					)
					s.emitRequest(r.Context(), protocol.SeverityWarn, requestID,
						"provider first-chunk timeout",
						map[string]any{
							"provider_id": provider.ID,
							"attempt":     attempt + 1,
							"reason":      "first_chunk_timeout",
						})
					if s.metrics != nil {
						s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
					}
					s.ddIncr("inference.dispatches", []string{"status:timeout"})
					provider = nil
					pr = nil
					continue
				case <-r.Context().Done():
					remainingDeadline.Stop()
					s.cancelDispatch(provider, pr)
					refundReservation()
					return
				}
			} else {
				// Backup dispatched — race primary vs backup.
				s.logger.Info("speculative_dispatch",
					"request_id", requestID,
					"primary_provider", provider.ID,
					"backup_provider", backupProvider.ID,
					"ttft_deadline_ms", deadline.Milliseconds(),
					"speculative_at_ms", speculativeAt.Milliseconds(),
				)

				raceDeadline := time.NewTimer(deadline - speculativeAt)

				select {
				case chunk, ok := <-pr.ChunkCh:
					// Primary wins!
					raceDeadline.Stop()
					s.cancelDispatch(backupProvider, backupPR)
					if ok {
						firstChunk = chunk
						pr.Timing.FirstChunkAt = time.Now()
						committed = true
					} else {
						select {
						case errMsg := <-pr.ErrorCh:
							// Primary failed but we already cancelled backup.
							excludeProviders[provider.ID] = struct{}{}
							s.cancelDispatch(provider, pr)
							lastErr = errMsg.Error
							lastErrCode = errMsg.StatusCode
							provider = nil
							pr = nil
							continue
						default:
							committed = true
						}
					}

				case chunk, ok := <-backupPR.ChunkCh:
					// Backup wins!
					raceDeadline.Stop()
					s.cancelDispatch(provider, pr)
					s.ddIncr("inference.speculative_win", []string{"model:" + model})
					if ok {
						provider = backupProvider
						pr = backupPR
						requestID = pr.RequestID
						firstChunk = chunk
						pr.Timing.FirstChunkAt = time.Now()
						committed = true
					} else {
						select {
						case errMsg := <-backupPR.ErrorCh:
							// Backup failed too. Keep primary context for retry.
							excludeProviders[backupProvider.ID] = struct{}{}
							// Wait remaining deadline for primary.
							remainingPrimary := time.NewTimer(deadline - speculativeAt)
							select {
							case chunk, ok := <-pr.ChunkCh:
								remainingPrimary.Stop()
								if ok {
									firstChunk = chunk
									pr.Timing.FirstChunkAt = time.Now()
									committed = true
								} else {
									select {
									case errMsg2 := <-pr.ErrorCh:
										excludeProviders[provider.ID] = struct{}{}
										s.cancelDispatch(provider, pr)
										lastErr = errMsg2.Error
										lastErrCode = errMsg2.StatusCode
										provider = nil
										pr = nil
										continue
									default:
										committed = true
									}
								}
							case <-pr.AcceptedCh:
								remainingPrimary.Stop()
								accepted = true
							case <-remainingPrimary.C:
								excludeProviders[provider.ID] = struct{}{}
								s.cancelDispatch(provider, pr)
								lastErr = errMsg.Error
								lastErrCode = errMsg.StatusCode
								provider = nil
								pr = nil
								continue
							case <-r.Context().Done():
								remainingPrimary.Stop()
								s.cancelDispatch(provider, pr)
								refundReservation()
								return
							}
						default:
							// Backup channel closed with no error — treat as committed.
							s.cancelDispatch(provider, pr)
							provider = backupProvider
							pr = backupPR
							requestID = pr.RequestID
							committed = true
						}
					}

				case <-pr.AcceptedCh:
					// Primary accepted (model reload). Cancel backup, extend deadline.
					raceDeadline.Stop()
					s.cancelDispatch(backupProvider, backupPR)
					accepted = true

				case <-backupPR.AcceptedCh:
					// Backup accepted (model reload). Cancel primary, extend deadline.
					raceDeadline.Stop()
					s.cancelDispatch(provider, pr)
					provider = backupProvider
					pr = backupPR
					requestID = pr.RequestID
					accepted = true

				case errMsg := <-pr.ErrorCh:
					// Primary failed. Keep waiting for backup.
					raceDeadline.Stop()
					excludeProviders[provider.ID] = struct{}{}
					s.cancelDispatch(provider, pr)
					// Wait for backup with remaining deadline.
					backupDeadline := time.NewTimer(deadline - speculativeAt)
					select {
					case chunk, ok := <-backupPR.ChunkCh:
						backupDeadline.Stop()
						_ = errMsg // used implicitly via excludeProviders
						if ok {
							provider = backupProvider
							pr = backupPR
							requestID = pr.RequestID
							firstChunk = chunk
							pr.Timing.FirstChunkAt = time.Now()
							committed = true
						} else {
							select {
							case errMsg2 := <-backupPR.ErrorCh:
								excludeProviders[backupProvider.ID] = struct{}{}
								s.cancelDispatch(backupProvider, backupPR)
								lastErr = errMsg2.Error
								lastErrCode = errMsg2.StatusCode
								provider = nil
								pr = nil
								continue
							default:
								provider = backupProvider
								pr = backupPR
								requestID = pr.RequestID
								committed = true
							}
						}
					case <-backupPR.AcceptedCh:
						backupDeadline.Stop()
						provider = backupProvider
						pr = backupPR
						requestID = pr.RequestID
						accepted = true
					case errMsg2 := <-backupPR.ErrorCh:
						backupDeadline.Stop()
						excludeProviders[backupProvider.ID] = struct{}{}
						s.cancelDispatch(backupProvider, backupPR)
						lastErr = errMsg2.Error
						lastErrCode = errMsg2.StatusCode
						provider = nil
						pr = nil
						continue
					case <-backupDeadline.C:
						excludeProviders[backupProvider.ID] = struct{}{}
						s.cancelDispatch(backupProvider, backupPR)
						lastErr = "timeout waiting for first response (backup)"
						lastErrCode = http.StatusGatewayTimeout
						if s.metrics != nil {
							s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
						}
						s.ddIncr("inference.dispatches", []string{"status:timeout"})
						provider = nil
						pr = nil
						continue
					case <-r.Context().Done():
						backupDeadline.Stop()
						s.cancelDispatch(backupProvider, backupPR)
						refundReservation()
						return
					}

				case errMsg := <-backupPR.ErrorCh:
					// Backup failed. Keep waiting for primary.
					raceDeadline.Stop()
					excludeProviders[backupProvider.ID] = struct{}{}
					s.cancelDispatch(backupProvider, backupPR)
					_ = errMsg
					primaryDeadline := time.NewTimer(deadline - speculativeAt)
					select {
					case chunk, ok := <-pr.ChunkCh:
						primaryDeadline.Stop()
						if ok {
							firstChunk = chunk
							pr.Timing.FirstChunkAt = time.Now()
							committed = true
						} else {
							select {
							case errMsg2 := <-pr.ErrorCh:
								excludeProviders[provider.ID] = struct{}{}
								s.cancelDispatch(provider, pr)
								lastErr = errMsg2.Error
								lastErrCode = errMsg2.StatusCode
								provider = nil
								pr = nil
								continue
							default:
								committed = true
							}
						}
					case <-pr.AcceptedCh:
						primaryDeadline.Stop()
						accepted = true
					case errMsg2 := <-pr.ErrorCh:
						primaryDeadline.Stop()
						excludeProviders[provider.ID] = struct{}{}
						s.cancelDispatch(provider, pr)
						lastErr = errMsg2.Error
						lastErrCode = errMsg2.StatusCode
						provider = nil
						pr = nil
						continue
					case <-primaryDeadline.C:
						excludeProviders[provider.ID] = struct{}{}
						s.cancelDispatch(provider, pr)
						lastErr = "timeout waiting for first response"
						lastErrCode = http.StatusGatewayTimeout
						if s.metrics != nil {
							s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
						}
						s.ddIncr("inference.dispatches", []string{"status:timeout"})
						provider = nil
						pr = nil
						continue
					case <-r.Context().Done():
						primaryDeadline.Stop()
						s.cancelDispatch(provider, pr)
						refundReservation()
						return
					}

				case <-raceDeadline.C:
					// Both missed deadline.
					s.cancelDispatch(provider, pr)
					s.cancelDispatch(backupProvider, backupPR)
					excludeProviders[provider.ID] = struct{}{}
					excludeProviders[backupProvider.ID] = struct{}{}
					lastErr = "timeout waiting for first response (both providers)"
					lastErrCode = http.StatusGatewayTimeout
					if s.metrics != nil {
						s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
					}
					s.ddIncr("inference.dispatches", []string{"status:timeout"})
					provider = nil
					pr = nil
					continue

				case <-r.Context().Done():
					raceDeadline.Stop()
					s.cancelDispatch(provider, pr)
					s.cancelDispatch(backupProvider, backupPR)
					refundReservation()
					return
				}
			}

		case <-deadlineTimer.C:
			speculativeTimer.Stop()
			excludeProviders[provider.ID] = struct{}{}
			s.cancelDispatch(provider, pr)
			lastErr = "timeout waiting for first response"
			lastErrCode = http.StatusGatewayTimeout
			s.logger.Warn("provider timeout (full deadline), retrying",
				"request_id", requestID,
				"provider_id", provider.ID,
				"attempt", attempt+1,
			)
			s.emitRequest(r.Context(), protocol.SeverityWarn, requestID,
				"provider first-chunk timeout",
				map[string]any{
					"provider_id": provider.ID,
					"attempt":     attempt + 1,
					"reason":      "first_chunk_timeout",
				})
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
			}
			s.ddIncr("inference.dispatches", []string{"status:timeout"})
			provider = nil
			pr = nil
			continue

		case <-r.Context().Done():
			speculativeTimer.Stop()
			deadlineTimer.Stop()
			s.cancelDispatch(provider, pr)
			refundReservation()
			return
		}

		// Provider accepted or sent first chunk — commit to this provider.
		// If only accepted (no chunk yet), wait for the first chunk with
		// the full inference timeout since the backend may be reloading.
		if accepted && !committed {
			chunkTimer := time.NewTimer(inferenceTimeout)
			select {
			case chunk, ok := <-pr.ChunkCh:
				chunkTimer.Stop()
				if ok {
					firstChunk = chunk
					pr.Timing.FirstChunkAt = time.Now()
					committed = true
				} else {
					// Closed — check for error. Use a short grace
					// period instead of a non-blocking default to
					// close the race where Go's select picks the
					// ChunkCh close before the ErrorCh value (sent
					// by the provider handler before closing ChunkCh).
					select {
					case errMsg := <-pr.ErrorCh:
						excludeProviders[provider.ID] = struct{}{}
						s.cancelDispatch(provider, pr)
						lastErr = errMsg.Error
						lastErrCode = errMsg.StatusCode
						s.logger.Warn("provider failed after accepting request, retrying",
							"request_id", requestID,
							"provider_id", provider.ID,
							"attempt", attempt+1,
							"error", errMsg.Error,
						)
						s.emitRequest(r.Context(), protocol.SeverityWarn, requestID,
							"provider failed after accepting request, retrying",
							map[string]any{
								"provider_id": provider.ID,
								"attempt":     attempt + 1,
								"reason":      "provider_error",
								"status_code": errMsg.StatusCode,
							})
						if s.metrics != nil {
							s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "retry"})
						}
						s.ddIncr("inference.dispatches", []string{"status:retry"})
						provider = nil
						pr = nil
						continue
					case <-time.After(50 * time.Millisecond):
						committed = true
					}
				}
			case errMsg := <-pr.ErrorCh:
				chunkTimer.Stop()
				excludeProviders[provider.ID] = struct{}{}
				s.cancelDispatch(provider, pr)
				lastErr = errMsg.Error
				lastErrCode = errMsg.StatusCode
				s.logger.Warn("provider failed after accepting request, retrying",
					"request_id", requestID,
					"provider_id", provider.ID,
					"attempt", attempt+1,
					"error", errMsg.Error,
				)
				s.emitRequest(r.Context(), protocol.SeverityWarn, requestID,
					"provider failed after accepting request, retrying",
					map[string]any{
						"provider_id": provider.ID,
						"attempt":     attempt + 1,
						"reason":      "provider_error",
						"status_code": errMsg.StatusCode,
					})
				if s.metrics != nil {
					s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "retry"})
				}
				s.ddIncr("inference.dispatches", []string{"status:retry"})
				provider = nil
				pr = nil
				continue
			case <-chunkTimer.C:
				excludeProviders[provider.ID] = struct{}{}
				s.cancelDispatch(provider, pr)
				lastErr = "provider accepted but timed out before first chunk"
				lastErrCode = http.StatusGatewayTimeout
				s.logger.Warn("provider timed out after accepting request, retrying",
					"request_id", requestID,
					"provider_id", provider.ID,
					"attempt", attempt+1,
				)
				s.emitRequest(r.Context(), protocol.SeverityWarn, requestID,
					"provider accepted timeout",
					map[string]any{
						"provider_id": provider.ID,
						"attempt":     attempt + 1,
						"reason":      "accepted_timeout",
					})
				if s.metrics != nil {
					s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
				}
				s.ddIncr("inference.dispatches", []string{"status:timeout"})
				provider = nil
				pr = nil
				continue
			case <-r.Context().Done():
				s.cancelDispatch(provider, pr)
				refundReservation()
				return
			}
		}

		break
	}

	if !committed {
		refundReservation()
		statusCode := lastErrCode
		if statusCode == 0 {
			// Distinguish capacity exhaustion (429) from genuine unavailability (503).
			// A quick capacity check tells us if providers exist but are full.
			_, capRej := s.registry.QuickCapacityCheck(model, estimatedPromptTokens, requestedMaxTokens, allowedProviderSerials...)
			if capRej > 0 {
				statusCode = http.StatusTooManyRequests
			} else {
				statusCode = http.StatusServiceUnavailable
			}
		}
		s.emitRequest(r.Context(), protocol.SeverityError, requestID,
			fmt.Sprintf("inference failed after %d attempt(s)", maxDispatchAttempts),
			map[string]any{
				"reason":      "dispatch_exhausted",
				"attempt":     maxDispatchAttempts,
				"status_code": statusCode,
				"last_error":  lastErr,
			})
		if s.metrics != nil {
			s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "failure"})
		}
		s.ddIncr("inference.dispatches", []string{"status:failure"})
		if statusCode == http.StatusTooManyRequests {
			retryAfter := s.estimateRetryAfter(model)
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
			writeJSON(w, statusCode, errorResponse("rate_limit_exceeded",
				fmt.Sprintf("all providers at capacity after %d attempt(s): %s", maxDispatchAttempts, lastErr),
				withCode("rate_limit_exceeded")))
		} else {
			writeJSON(w, statusCode, errorResponse("provider_error",
				fmt.Sprintf("inference failed after %d attempt(s): %s", maxDispatchAttempts, lastErr)))
		}
		return
	}
	if s.metrics != nil {
		s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "success"})
	}
	s.ddIncr("inference.dispatches", []string{"status:success"})

	// Write provider attestation headers now that we're committed.
	provider.Mu().Lock()
	pubKey := provider.PublicKey
	attested := provider.Attested
	trustLevel := provider.TrustLevel
	attestResult := provider.AttestationResult
	mdaVerified := provider.MDAVerified
	provider.Mu().Unlock()

	providerID := provider.ID
	chipName := provider.Hardware.ChipName
	machineModel := provider.Hardware.MachineModel

	if pubKey != "" {
		w.Header().Set("X-Provider-Encrypted", "true")
	}
	if attested {
		w.Header().Set("X-Provider-Attested", "true")
	} else {
		w.Header().Set("X-Provider-Attested", "false")
	}
	w.Header().Set("X-Provider-Trust-Level", string(trustLevel))
	w.Header().Set("X-Provider-Id", providerID)
	w.Header().Set("X-Provider-Chip", chipName)
	w.Header().Set("X-Provider-Model", machineModel)
	if attestResult != nil {
		w.Header().Set("X-Provider-Serial", attestResult.SerialNumber)
		if attestResult.SecureEnclaveAvailable {
			w.Header().Set("X-Provider-Secure-Enclave", "true")
		} else {
			w.Header().Set("X-Provider-Secure-Enclave", "false")
		}
	}
	if mdaVerified {
		w.Header().Set("X-Provider-Mda-Verified", "true")
	}
	// SE public key for attestation receipt verification.
	// Consumers can use this to verify SE signatures on response hashes.
	if attestResult != nil && attestResult.PublicKey != "" {
		w.Header().Set("X-Attestation-Se-Public-Key", attestResult.PublicKey)
		w.Header().Set("X-Attestation-Device-Serial", attestResult.SerialNumber)
	}

	// Latency decomposition header for observability.
	if timing := pr.Timing; timing != nil {
		type timingJSON struct {
			ParseUs    int64 `json:"parse_us"`
			ReserveUs  int64 `json:"reserve_us"`
			RouteUs    int64 `json:"route_us"`
			QueueUs    int64 `json:"queue_us"`
			EncryptUs  int64 `json:"encrypt_us"`
			DispatchUs int64 `json:"dispatch_us"`
			ProviderUs int64 `json:"provider_us"`
		}
		tj := timingJSON{}
		if !timing.ParsedAt.IsZero() {
			tj.ParseUs = timing.ParsedAt.Sub(timing.ReceivedAt).Microseconds()
		}
		if !timing.ReservedAt.IsZero() && !timing.ParsedAt.IsZero() {
			tj.ReserveUs = timing.ReservedAt.Sub(timing.ParsedAt).Microseconds()
		}
		if !timing.RoutedAt.IsZero() && !timing.ReservedAt.IsZero() {
			tj.RouteUs = timing.RoutedAt.Sub(timing.ReservedAt).Microseconds()
		}
		if !timing.QueuedAt.IsZero() && !timing.DispatchedAt.IsZero() {
			tj.QueueUs = timing.DispatchedAt.Sub(timing.QueuedAt).Microseconds()
		}
		if !timing.EncryptedAt.IsZero() && !timing.RoutedAt.IsZero() {
			tj.EncryptUs = timing.EncryptedAt.Sub(timing.RoutedAt).Microseconds()
		}
		if !timing.DispatchedAt.IsZero() && !timing.EncryptedAt.IsZero() {
			tj.DispatchUs = timing.DispatchedAt.Sub(timing.EncryptedAt).Microseconds()
		}
		if !timing.FirstChunkAt.IsZero() && !timing.DispatchedAt.IsZero() {
			tj.ProviderUs = timing.FirstChunkAt.Sub(timing.DispatchedAt).Microseconds()
		}
		if tjJSON, err := json.Marshal(tj); err == nil {
			w.Header().Set("X-Timing", string(tjJSON))
		}
	}

	// When this function returns (consumer disconnect, timeout, or completion),
	// send a cancel to the provider so it stops generating tokens.
	defer func() {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.sendProviderCancel(provider, requestID)
	}()

	if stream {
		s.handleStreamingResponseWithFirstChunk(w, r, pr, firstChunk)
	} else {
		s.handleNonStreamingResponseWithFirstChunk(w, r, pr, firstChunk)
	}
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
	rawBody, err := io.ReadAll(r.Body)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "failed to read request body"))
		return
	}

	var parsed map[string]any
	if err := json.Unmarshal(rawBody, &parsed); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}

	model, _ := parsed["model"].(string)
	if model == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "model is required", withParam("model")))
		return
	}
	// Per-key model allow-list enforcement (phase 3).
	if !s.keyModelAllowed(r.Context(), model) {
		writeJSON(w, http.StatusForbidden, errorResponse("model_not_allowed",
			fmt.Sprintf("this API key is not permitted to use model %q", model), withParam("model")))
		return
	}
	if !s.registry.IsModelInCatalog(model) {
		writeJSON(w, http.StatusNotFound, errorResponse("model_not_found",
			fmt.Sprintf("model %q is not available — see /v1/models for supported models", model), withParam("model")))
		return
	}

	allowedProviderSerials, hasProviderAllowlist, err := parseProviderSerialAllowlist(parsed)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", err.Error()))
		return
	}
	if hasProviderAllowlist {
		stripProviderRoutingFields(parsed)
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

	// Inject the endpoint so the provider knows which local path to forward to.
	parsed["endpoint"] = endpoint

	// Per-account token rate limiting (ITPM/OTPM), before the reservation.
	if !s.applyTokenRateLimit(w, r, estimatedPromptTokens, requestedMaxTokens) {
		return
	}

	// Pre-flight balance reservation — same worst-case-cost reservation as
	// handleChatCompletions, using the byte-length upper bound for prompt
	// tokens so the reservation always covers actual cost.
	consumerKey := consumerKeyFromContext(r.Context())
	consumerLocation := s.requestLocation(r)
	var reservedMicroUSD int64
	if s.billing != nil {
		reservedMicroUSD = s.reservationCost(model, billingPromptTokens, requestedMaxTokens)
		// Per-key spend cap (phase 1) — checked before the reservation.
		if msg, ok := s.checkKeySpendCap(r.Context(), reservedMicroUSD); !ok {
			writeJSON(w, http.StatusPaymentRequired, errorResponse("insufficient_quota", msg, withCode("insufficient_quota")))
			return
		}
		start := time.Now()
		if err := s.ledger.Charge(consumerKey, reservedMicroUSD, "reserve:"+consumerKey); err != nil {
			if errors.Is(err, store.ErrInsufficientBalance) {
				writeJSON(w, http.StatusPaymentRequired, errorResponse("insufficient_funds",
					"your balance is too low for this request — add funds at /billing or lower max_tokens", withCode("insufficient_quota")))
			} else {
				s.logger.Error("balance reservation failed (DB error)", "consumer_key", consumerKey, "error", err)
				writeJSON(w, http.StatusServiceUnavailable, errorResponse("service_unavailable",
					"service temporarily unavailable — please retry"))
			}
			return
		}
		s.ddHistogram("billing.reserved_micro_usd", float64(reservedMicroUSD), []string{"model:" + model})
		s.ddHistogram("store.debit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:reserve"})
	}
	refundReservation := func() {
		if reservedMicroUSD > 0 {
			start := time.Now()
			_ = s.store.Credit(consumerKey, reservedMicroUSD, store.LedgerRefund, "reservation_refund")
			s.ddIncr("billing.reservation_refunds", []string{"model:" + model})
			s.ddHistogram("store.credit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:reservation_refund"})
		}
	}

	// Pre-flight capacity check (same logic as handleChatCompletions).
	candidateCount, capacityRejections := s.registry.QuickCapacityCheck(model, estimatedPromptTokens, requestedMaxTokens, allowedProviderSerials...)
	if candidateCount == 0 && capacityRejections > 0 {
		retryAfter := s.estimateRetryAfter(model)
		w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
		refundReservation()
		s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:capacity_429"})
		writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
			fmt.Sprintf("all providers for model %q are at capacity — retry after %ds", model, retryAfter),
			withCode("rate_limit_exceeded")))
		return
	}

	requestID := uuid.New().String()
	pr := &registry.PendingRequest{
		RequestID:              requestID,
		Model:                  model,
		ConsumerKey:            consumerKey,
		KeyID:                  keyIDFromContext(r.Context()),
		KeyLimitMicroUSD:       keyLimitMicroFromContext(r.Context()),
		KeyLimitReset:          keyLimitResetFromContext(r.Context()),
		ConsumerLocation:       consumerLocation,
		AllowedProviderSerials: allowedProviderSerials,
		EstimatedPromptTokens:  estimatedPromptTokens,
		RequestedMaxTokens:     requestedMaxTokens,
		ReservedMicroUSD:       reservedMicroUSD,
		BaseReservedMicroUSD:   reservedMicroUSD,
		AcceptedCh:             make(chan struct{}, 1),
		ChunkCh:                make(chan string, chunkBufferSize),
		CompleteCh:             make(chan protocol.UsageInfo, 1),
		ErrorCh:                make(chan protocol.InferenceErrorMessage, 1),
	}

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

		if s.billing != nil && !providerHasPayoutDestination(provider) {
			s.logger.Warn("provider missing payout destination, crediting to internal ledger",
				"provider_id", provider.ID)
		}

		// Custom pricing check — provider may charge more than the platform rate.
		if s.billing != nil {
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
			writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
				fmt.Sprintf("all providers for model %q are at capacity and queue is full", model),
				withCode("rate_limit_exceeded")))
			return
		}
		s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:queued"})
		provider, err = s.registry.Queue().WaitForProviderContext(r.Context(), queuedReq)
		if err != nil {
			if errors.Is(err, context.Canceled) {
				refundReservation()
				return
			}
			retryAfter := s.estimateRetryAfter(model)
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
			refundReservation()
			writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
				fmt.Sprintf("all providers for model %q are at capacity (queue timeout)", model),
				withCode("rate_limit_exceeded")))
			return
		}
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
	if s.billing != nil && !providerHasPayoutDestination(provider) {
		s.logger.Warn("provider missing payout destination, crediting to internal ledger",
			"provider_id", provider.ID)
	}
	if s.billing != nil {
		if _, err := s.reserveAdditionalForProvider(pr, provider); err != nil {
			cleanupPending()
			refundExtra()
			refundReservation()
			if errors.Is(err, store.ErrInsufficientBalance) {
				writeJSON(w, http.StatusPaymentRequired, errorResponse("insufficient_funds",
					"your balance is too low for this provider price — add funds at /billing or lower max_tokens", withCode("insufficient_quota")))
			} else {
				s.logger.Error("provider reservation failed (DB error)", "consumer_key", consumerKey, "error", err)
				writeJSON(w, http.StatusServiceUnavailable, errorResponse("service_unavailable",
					"service temporarily unavailable — please retry"))
			}
			return
		}
	}

	inferenceBody, _ := json.Marshal(parsed)

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
	genericDeadline := ttftDeadline(estimatedPromptTokens)
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

	// When this function returns (consumer disconnect, timeout, or
	// completion), tell the provider to stop generating. Without this the
	// provider keeps producing tokens into a buffered channel until the
	// buffer fills, wasting GPU cycles.
	defer func() {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.sendProviderCancel(provider, requestID)
	}()

	if stream {
		s.handleStreamingResponseWithFirstChunk(w, r, pr, firstChunk)
	} else {
		s.handleNonStreamingResponseWithFirstChunk(w, r, pr, firstChunk)
	}
}
