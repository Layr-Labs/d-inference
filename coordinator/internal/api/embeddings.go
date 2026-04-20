package api

// Disaggregated compute endpoints — embeddings and reranking.
//
// These endpoints exist so low-RAM Mac providers (Air, 16 GB Mini) — which
// cannot host a quality decoder LLM in memory — still earn revenue and add
// useful capacity to the network. Embeddings and rerankers run on small
// (100 MB – 2 GB) models that comfortably fit in 8–16 GB and are bottlenecked
// by GPU compute, not memory bandwidth, so a small Mac is genuinely fast at
// them. Routing prefers small/tiny tier providers (see
// registry.PreferredTiersForModelType) so big-RAM machines stay free for
// memory-bandwidth-bound decode of large language models.
//
// API surface mirrors the OpenAI /v1/embeddings shape; rerank mirrors
// Cohere's /v1/rerank, which is the de-facto standard supported by
// LangChain, LlamaIndex, Haystack, and most retrieval stacks.

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/eigeninference/coordinator/internal/e2e"
	"github.com/eigeninference/coordinator/internal/payments"
	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
	"github.com/google/uuid"
	"nhooyr.io/websocket"
)

const (
	// embeddingTimeout is the max time we'll wait for an embedding/rerank
	// result. Embeddings are short-lived (sub-second to a few seconds for
	// large batches) — if it takes longer than this the provider is wedged.
	embeddingTimeout = 60 * time.Second

	// embeddingChannelChunkBuffer is reused for the small set of channels we
	// allocate per embedding/rerank request — small because nothing streams.
	embeddingChannelChunkBuffer = 1

	// embeddingMaxAttempts is the number of provider dispatch attempts
	// before returning an error to the consumer. Mirrors maxDispatchAttempts
	// on the chat path so a single flaky small-tier provider doesn't kill a
	// request.
	embeddingMaxAttempts = 3
)

// estimateEmbeddingPromptTokens returns an approximate token count for an
// embedding request body. The `input` field is a JSON value that is either
// a string or an array of strings; we approximate ~4 chars per token.
func estimateEmbeddingPromptTokens(input json.RawMessage) int {
	if len(input) == 0 {
		return 0
	}
	var s string
	if err := json.Unmarshal(input, &s); err == nil {
		return approxTokens(s)
	}
	var arr []string
	if err := json.Unmarshal(input, &arr); err == nil {
		total := 0
		for _, item := range arr {
			total += approxTokens(item)
		}
		return total
	}
	// OpenAI also accepts pre-tokenized inputs (arrays of token IDs).
	var tokenArrays [][]int
	if err := json.Unmarshal(input, &tokenArrays); err == nil {
		total := 0
		for _, item := range tokenArrays {
			total += len(item)
		}
		return total
	}
	return len(input) / 4
}

// approxTokens is a conservative ~4-chars-per-token estimate used for
// pre-flight billing reservations on embedding requests.
func approxTokens(s string) int {
	if s == "" {
		return 0
	}
	t := len(s) / 4
	if t < 1 {
		t = 1
	}
	return t
}

// estimateRerankPromptTokens approximates the total tokens scored across all
// (query, document) pairs. A cross-encoder runs one forward pass per pair,
// each pair concatenates query + document, so we bill on the sum.
func estimateRerankPromptTokens(query string, documents []string) int {
	queryTokens := approxTokens(query)
	total := 0
	for _, d := range documents {
		total += queryTokens + approxTokens(d)
	}
	return total
}

// handleEmbeddings handles POST /v1/embeddings.
//
// The request body matches OpenAI's /v1/embeddings:
//
//	{ "model": "...", "input": "..." | ["..."], "encoding_format": "float", "dimensions": int? }
//
// The coordinator estimates token cost up-front, reserves the worst-case
// charge against the consumer's balance, routes to a small-tier provider
// (with E2E encryption mandatory), and returns the OpenAI-shaped response.
func (s *Server) handleEmbeddings(w http.ResponseWriter, r *http.Request) {
	rawBody, err := io.ReadAll(r.Body)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "failed to read request body"))
		return
	}

	var req protocol.EmbeddingRequestBody
	if err := json.Unmarshal(rawBody, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.Model == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "model is required"))
		return
	}
	if len(req.Input) == 0 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "input is required"))
		return
	}
	// We only emit float arrays today. Refuse base64 explicitly so consumers
	// know rather than silently getting the wrong shape.
	if req.EncodingFormat != "" && req.EncodingFormat != "float" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			"encoding_format must be 'float' (base64 not yet supported)"))
		return
	}
	if !s.registry.IsModelInCatalog(req.Model) {
		writeJSON(w, http.StatusNotFound, errorResponse("model_not_found",
			fmt.Sprintf("model %q is not available — see /v1/models for supported models", req.Model)))
		return
	}

	consumerKey := consumerKeyFromContext(r.Context())
	estimatedTokens := estimateEmbeddingPromptTokens(req.Input)
	customRate, _, hasCustom := s.store.GetModelPrice("platform", req.Model)

	// Pre-flight reservation. Both the charge AND the reservation amount are
	// gated on s.billing != nil so a deployment without billing wired up
	// cannot accidentally credit consumers via the refund path. The chat
	// handler in consumer.go uses the same pattern (declares reservedMicroUSD
	// inside the if-billing block); embeddings/rerank now mirror that.
	var reservedMicroUSD int64
	if s.billing != nil {
		if hasCustom {
			reservedMicroUSD = int64(estimatedTokens) * customRate / 1_000_000
			if reservedMicroUSD < payments.MinimumCharge() {
				reservedMicroUSD = payments.MinimumCharge()
			}
		} else {
			reservedMicroUSD = payments.CalculateEmbeddingCost(req.Model, estimatedTokens)
		}
		if err := s.ledger.Charge(consumerKey, reservedMicroUSD, "reserve:"+consumerKey); err != nil {
			writeJSON(w, http.StatusPaymentRequired, errorResponse("insufficient_funds",
				"your balance is too low for this request — add funds at /billing"))
			return
		}
	}

	// refund only credits when there was a corresponding charge. Without
	// this guard, error paths in a billing-disabled deployment would mint
	// free balance.
	refund := func(amount int64) {
		if amount > 0 && s.billing != nil {
			_ = s.store.Credit(consumerKey, amount, store.LedgerRefund, "embedding_refund")
		}
	}

	// Cross-provider retry — mirrors the chat path so a single flaky small
	// provider doesn't fail the request. Excluded providers are tried again
	// on the next inbound embedding request once they recover.
	excludeProviders := make(map[string]struct{})
	excludeList := func() []string {
		ids := make([]string, 0, len(excludeProviders))
		for id := range excludeProviders {
			ids = append(ids, id)
		}
		return ids
	}

	ctx, cancel := context.WithTimeout(r.Context(), embeddingTimeout)
	defer cancel()

	var (
		lastErrCode = http.StatusServiceUnavailable
		lastErr     = "no provider available"
	)

	for attempt := 0; attempt < embeddingMaxAttempts; attempt++ {
		requestID := uuid.New().String()
		pr := &registry.PendingRequest{
			RequestID:             requestID,
			Model:                 req.Model,
			ConsumerKey:           consumerKey,
			EstimatedPromptTokens: estimatedTokens,
			RequestedMaxTokens:    1, // embeddings produce no completion tokens
			ReservedMicroUSD:      reservedMicroUSD,
			ChunkCh:               make(chan string, embeddingChannelChunkBuffer),
			CompleteCh:            make(chan protocol.UsageInfo, 1),
			ErrorCh:               make(chan protocol.InferenceErrorMessage, 1),
			EmbeddingCh:           make(chan *protocol.EmbeddingCompleteMessage, 1),
		}

		provider := s.registry.ReserveProvider(req.Model, pr, excludeList()...)
		if provider == nil {
			break
		}

		ok, errMsg, errCode, result := s.dispatchEmbedding(ctx, r, req.Model, rawBody, requestID, provider, pr)
		if !ok {
			excludeProviders[provider.ID] = struct{}{}
			lastErr = errMsg
			if errCode != 0 {
				lastErrCode = errCode
			}
			continue
		}

		// Success. Compute actual cost from reported usage and refund
		// the difference. Clamp to the reservation so a misbehaving
		// provider can never overcharge. When billing is disabled
		// (reservedMicroUSD == 0) we skip clamp/refund — the cost
		// computation is still useful to record on the usage entry.
		actualTokens := int(result.Usage.PromptTokens)
		if actualTokens <= 0 {
			actualTokens = estimatedTokens
		}
		actualCost := computeEmbeddingCost(req.Model, actualTokens, customRate, hasCustom)
		if reservedMicroUSD > 0 {
			if actualCost > reservedMicroUSD {
				s.logger.Error("embedding provider over-reported usage — clamping to reservation",
					"provider_id", provider.ID,
					"request_id", requestID,
					"actual_cost", actualCost,
					"reserved", reservedMicroUSD,
				)
				actualCost = reservedMicroUSD
			}
			if actualCost < reservedMicroUSD {
				refund(reservedMicroUSD - actualCost)
			}
		}

		s.recordDisaggregatedBilling(provider, pr, requestID, req.Model, actualTokens, actualCost, result.DurationSecs)

		writeJSON(w, http.StatusOK, map[string]any{
			"object": "list",
			"model":  req.Model,
			"data":   formatEmbeddingData(result.Data),
			"usage": map[string]any{
				"prompt_tokens": actualTokens,
				"total_tokens":  actualTokens,
			},
		})
		return
	}

	refund(reservedMicroUSD)
	writeJSON(w, lastErrCode, errorResponse("provider_error",
		fmt.Sprintf("embedding failed after %d attempt(s): %s", embeddingMaxAttempts, lastErr)))
}

// dispatchEmbedding dispatches one embedding attempt to a reserved provider
// and either returns (true, …, result) on success or (false, errMsg, code, nil)
// on failure. On every exit path it cleans up the pending request and the
// provider's serving state.
func (s *Server) dispatchEmbedding(
	ctx context.Context,
	r *http.Request,
	model string,
	rawBody []byte,
	requestID string,
	provider *registry.Provider,
	pr *registry.PendingRequest,
) (bool, string, int, *protocol.EmbeddingCompleteMessage) {
	cleanup := func() {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
	}

	if provider.PublicKey == "" {
		cleanup()
		return false, "no provider with E2E encryption available", 0, nil
	}

	providerPubKey, err := e2e.ParsePublicKey(provider.PublicKey)
	if err != nil {
		cleanup()
		return false, "provider public key invalid", 0, nil
	}

	sessionKeys, err := e2e.GenerateSessionKeys()
	if err != nil {
		cleanup()
		return false, "failed to generate session keys", 0, nil
	}
	pr.SessionPrivKey = &sessionKeys.PrivateKey

	encrypted, err := e2e.Encrypt(rawBody, providerPubKey, sessionKeys)
	if err != nil {
		cleanup()
		return false, "failed to encrypt request", 0, nil
	}

	wireMsg := map[string]any{
		"type":       protocol.TypeEmbeddingRequest,
		"request_id": requestID,
		"encrypted_body": map[string]string{
			"ephemeral_public_key": encrypted.EphemeralPublicKey,
			"ciphertext":           encrypted.Ciphertext,
		},
	}
	data, _ := json.Marshal(wireMsg)
	if err := provider.Conn.Write(r.Context(), websocket.MessageText, data); err != nil {
		cleanup()
		s.logger.Error("failed to send embedding request",
			"request_id", requestID, "provider_id", provider.ID, "error", err)
		return false, "failed to send request to provider", 0, nil
	}

	s.logger.Info("embedding request dispatched",
		"request_id", requestID,
		"model", model,
		"provider_id", provider.ID,
		"provider_tier", provider.Tier,
		"estimated_tokens", pr.EstimatedPromptTokens,
	)

	select {
	case result := <-pr.EmbeddingCh:
		// Success path: cleanup is handled inside handleEmbeddingComplete
		// (RemovePending) and recordDisaggregatedBilling (SetProviderIdle).
		// We still re-idle here defensively; SetProviderIdle is a no-op
		// when pending count is non-zero.
		s.registry.SetProviderIdle(provider.ID)
		if result == nil {
			return false, "embedding provider closed channel", 0, nil
		}
		// Decrypt the response payload if the provider sealed it back to
		// our session key.
		if result.EncryptedData != nil {
			payload := &e2e.EncryptedPayload{
				EphemeralPublicKey: result.EncryptedData.EphemeralPublicKey,
				Ciphertext:         result.EncryptedData.Ciphertext,
			}
			plaintext, derr := e2e.DecryptWithPrivateKey(payload, sessionKeys.PrivateKey)
			if derr != nil {
				// Treat decrypt failure as a provider failure for reputation.
				s.registry.RecordJobFailure(provider.ID)
				return false, "failed to decrypt embedding response: " + derr.Error(), http.StatusBadGateway, nil
			}
			var vectors []protocol.EmbeddingVector
			if uerr := json.Unmarshal(plaintext, &vectors); uerr != nil {
				s.registry.RecordJobFailure(provider.ID)
				return false, "invalid encrypted embedding response: " + uerr.Error(), http.StatusBadGateway, nil
			}
			result.Data = vectors
		}
		return true, "", 0, result

	case errMsg := <-pr.ErrorCh:
		// handleInferenceError already removed pending + closed channels.
		s.registry.SetProviderIdle(provider.ID)
		code := errMsg.StatusCode
		if code == 0 {
			code = http.StatusBadGateway
		}
		return false, errMsg.Error, code, nil

	case <-ctx.Done():
		cleanup()
		return false, "embedding request timed out", http.StatusGatewayTimeout, nil
	}
}

// handleRerank handles POST /v1/rerank.
//
// Mirrors Cohere's /v1/rerank API:
//
//	{ "model": "...", "query": "...", "documents": ["..."], "top_n": int?, "return_documents": bool? }
func (s *Server) handleRerank(w http.ResponseWriter, r *http.Request) {
	rawBody, err := io.ReadAll(r.Body)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "failed to read request body"))
		return
	}

	var req protocol.RerankRequestBody
	if err := json.Unmarshal(rawBody, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.Model == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "model is required"))
		return
	}
	if req.Query == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "query is required"))
		return
	}
	if len(req.Documents) == 0 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "documents must be non-empty"))
		return
	}
	if !s.registry.IsModelInCatalog(req.Model) {
		writeJSON(w, http.StatusNotFound, errorResponse("model_not_found",
			fmt.Sprintf("model %q is not available — see /v1/models for supported models", req.Model)))
		return
	}

	consumerKey := consumerKeyFromContext(r.Context())
	estimatedTokens := estimateRerankPromptTokens(req.Query, req.Documents)
	customRate, _, hasCustom := s.store.GetModelPrice("platform", req.Model)

	var reservedMicroUSD int64
	if s.billing != nil {
		if hasCustom {
			reservedMicroUSD = int64(estimatedTokens) * customRate / 1_000_000
			if reservedMicroUSD < payments.MinimumCharge() {
				reservedMicroUSD = payments.MinimumCharge()
			}
		} else {
			reservedMicroUSD = payments.CalculateRerankCost(req.Model, estimatedTokens)
		}
		if err := s.ledger.Charge(consumerKey, reservedMicroUSD, "reserve:"+consumerKey); err != nil {
			writeJSON(w, http.StatusPaymentRequired, errorResponse("insufficient_funds",
				"your balance is too low for this request — add funds at /billing"))
			return
		}
	}

	refund := func(amount int64) {
		if amount > 0 && s.billing != nil {
			_ = s.store.Credit(consumerKey, amount, store.LedgerRefund, "rerank_refund")
		}
	}

	excludeProviders := make(map[string]struct{})
	excludeList := func() []string {
		ids := make([]string, 0, len(excludeProviders))
		for id := range excludeProviders {
			ids = append(ids, id)
		}
		return ids
	}

	ctx, cancel := context.WithTimeout(r.Context(), embeddingTimeout)
	defer cancel()

	var (
		lastErrCode = http.StatusServiceUnavailable
		lastErr     = "no provider available"
	)

	for attempt := 0; attempt < embeddingMaxAttempts; attempt++ {
		requestID := uuid.New().String()
		pr := &registry.PendingRequest{
			RequestID:             requestID,
			Model:                 req.Model,
			ConsumerKey:           consumerKey,
			EstimatedPromptTokens: estimatedTokens,
			RequestedMaxTokens:    1,
			ReservedMicroUSD:      reservedMicroUSD,
			ChunkCh:               make(chan string, embeddingChannelChunkBuffer),
			CompleteCh:            make(chan protocol.UsageInfo, 1),
			ErrorCh:               make(chan protocol.InferenceErrorMessage, 1),
			RerankCh:              make(chan *protocol.RerankCompleteMessage, 1),
		}

		provider := s.registry.ReserveProvider(req.Model, pr, excludeList()...)
		if provider == nil {
			break
		}

		ok, errMsg, errCode, result := s.dispatchRerank(ctx, r, req.Model, rawBody, requestID, provider, pr)
		if !ok {
			excludeProviders[provider.ID] = struct{}{}
			lastErr = errMsg
			if errCode != 0 {
				lastErrCode = errCode
			}
			continue
		}

		actualTokens := int(result.Usage.PromptTokens)
		if actualTokens <= 0 {
			actualTokens = estimatedTokens
		}
		actualCost := computeRerankCost(req.Model, actualTokens, customRate, hasCustom)
		if reservedMicroUSD > 0 {
			if actualCost > reservedMicroUSD {
				s.logger.Error("rerank provider over-reported usage — clamping to reservation",
					"provider_id", provider.ID,
					"request_id", requestID,
					"actual_cost", actualCost,
					"reserved", reservedMicroUSD,
				)
				actualCost = reservedMicroUSD
			}
			if actualCost < reservedMicroUSD {
				refund(reservedMicroUSD - actualCost)
			}
		}

		results := result.Results
		if req.TopN != nil && *req.TopN > 0 && len(results) > *req.TopN {
			results = results[:*req.TopN]
		}

		s.recordDisaggregatedBilling(provider, pr, requestID, req.Model, actualTokens, actualCost, result.DurationSecs)

		writeJSON(w, http.StatusOK, map[string]any{
			"id":      "rerank-" + requestID,
			"model":   req.Model,
			"results": results,
			"usage": map[string]any{
				"prompt_tokens": actualTokens,
				"total_tokens":  actualTokens,
			},
		})
		return
	}

	refund(reservedMicroUSD)
	writeJSON(w, lastErrCode, errorResponse("provider_error",
		fmt.Sprintf("rerank failed after %d attempt(s): %s", embeddingMaxAttempts, lastErr)))
}

// dispatchRerank dispatches one rerank attempt to a reserved provider.
// Returns (success, errMsg, errCode, result). On every exit path it cleans
// up the pending request and the provider's serving state.
func (s *Server) dispatchRerank(
	ctx context.Context,
	r *http.Request,
	model string,
	rawBody []byte,
	requestID string,
	provider *registry.Provider,
	pr *registry.PendingRequest,
) (bool, string, int, *protocol.RerankCompleteMessage) {
	cleanup := func() {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
	}

	if provider.PublicKey == "" {
		cleanup()
		return false, "no provider with E2E encryption available", 0, nil
	}
	providerPubKey, err := e2e.ParsePublicKey(provider.PublicKey)
	if err != nil {
		cleanup()
		return false, "provider public key invalid", 0, nil
	}
	sessionKeys, err := e2e.GenerateSessionKeys()
	if err != nil {
		cleanup()
		return false, "failed to generate session keys", 0, nil
	}
	pr.SessionPrivKey = &sessionKeys.PrivateKey

	encrypted, err := e2e.Encrypt(rawBody, providerPubKey, sessionKeys)
	if err != nil {
		cleanup()
		return false, "failed to encrypt request", 0, nil
	}

	wireMsg := map[string]any{
		"type":       protocol.TypeRerankRequest,
		"request_id": requestID,
		"encrypted_body": map[string]string{
			"ephemeral_public_key": encrypted.EphemeralPublicKey,
			"ciphertext":           encrypted.Ciphertext,
		},
	}
	data, _ := json.Marshal(wireMsg)
	if err := provider.Conn.Write(r.Context(), websocket.MessageText, data); err != nil {
		cleanup()
		s.logger.Error("failed to send rerank request",
			"request_id", requestID, "provider_id", provider.ID, "error", err)
		return false, "failed to send request to provider", 0, nil
	}

	s.logger.Info("rerank request dispatched",
		"request_id", requestID,
		"model", model,
		"provider_id", provider.ID,
		"provider_tier", provider.Tier,
		"estimated_tokens", pr.EstimatedPromptTokens,
	)

	select {
	case result := <-pr.RerankCh:
		s.registry.SetProviderIdle(provider.ID)
		if result == nil {
			return false, "rerank provider closed channel", 0, nil
		}
		if result.EncryptedData != nil {
			payload := &e2e.EncryptedPayload{
				EphemeralPublicKey: result.EncryptedData.EphemeralPublicKey,
				Ciphertext:         result.EncryptedData.Ciphertext,
			}
			plaintext, derr := e2e.DecryptWithPrivateKey(payload, sessionKeys.PrivateKey)
			if derr != nil {
				s.registry.RecordJobFailure(provider.ID)
				return false, "failed to decrypt rerank response: " + derr.Error(), http.StatusBadGateway, nil
			}
			var rs []protocol.RerankResult
			if uerr := json.Unmarshal(plaintext, &rs); uerr != nil {
				s.registry.RecordJobFailure(provider.ID)
				return false, "invalid encrypted rerank response: " + uerr.Error(), http.StatusBadGateway, nil
			}
			result.Results = rs
		}
		return true, "", 0, result

	case errMsg := <-pr.ErrorCh:
		s.registry.SetProviderIdle(provider.ID)
		code := errMsg.StatusCode
		if code == 0 {
			code = http.StatusBadGateway
		}
		return false, errMsg.Error, code, nil

	case <-ctx.Done():
		cleanup()
		return false, "rerank request timed out", http.StatusGatewayTimeout, nil
	}
}

// computeEmbeddingCost is the single source of truth for embedding pricing,
// honoring platform-level custom rates when present.
func computeEmbeddingCost(model string, tokens int, customRate int64, hasCustom bool) int64 {
	if hasCustom {
		cost := int64(tokens) * customRate / 1_000_000
		if cost < payments.MinimumCharge() {
			cost = payments.MinimumCharge()
		}
		return cost
	}
	return payments.CalculateEmbeddingCost(model, tokens)
}

func computeRerankCost(model string, tokens int, customRate int64, hasCustom bool) int64 {
	if hasCustom {
		cost := int64(tokens) * customRate / 1_000_000
		if cost < payments.MinimumCharge() {
			cost = payments.MinimumCharge()
		}
		return cost
	}
	return payments.CalculateRerankCost(model, tokens)
}

// recordDisaggregatedBilling records usage + provider payout for an embedding
// or rerank job. Same shape as the chat-completions billing path so admin
// dashboards see uniform data. durationSecs comes from the provider's
// reported processing time (used for the reputation system's response-time
// component).
func (s *Server) recordDisaggregatedBilling(
	provider *registry.Provider,
	pr *registry.PendingRequest,
	requestID, model string,
	tokens int,
	totalCost int64,
	durationSecs float64,
) {
	providerPayout := payments.ProviderPayout(totalCost)

	s.ledger.RecordUsage(pr.ConsumerKey, payments.UsageEntry{
		JobID:        requestID,
		Model:        model,
		PromptTokens: tokens,
		CostMicroUSD: totalCost,
		Timestamp:    time.Now(),
	})
	s.store.RecordUsageWithCost(provider.ID, pr.ConsumerKey, model, requestID, tokens, 0, totalCost)

	// Use the provider-reported duration for reputation. Falling back to a
	// constant when missing keeps a misbehaving (or pre-update) provider
	// from getting a free 0 ms response time.
	respTime := time.Duration(durationSecs * float64(time.Second))
	if respTime <= 0 {
		respTime = 100 * time.Millisecond
	}
	s.registry.RecordJobSuccess(provider.ID, respTime)

	if provider.AccountID != "" {
		if err := s.store.CreditProviderAccount(&store.ProviderEarning{
			AccountID:      provider.AccountID,
			ProviderID:     provider.ID,
			ProviderKey:    provider.PublicKey,
			JobID:          requestID,
			Model:          model,
			AmountMicroUSD: providerPayout,
			PromptTokens:   tokens,
			CreatedAt:      time.Now(),
		}); err != nil {
			s.logger.Error("failed to credit linked provider account for embedding/rerank",
				"provider_id", provider.ID,
				"account_id", provider.AccountID,
				"request_id", requestID,
				"error", err,
			)
		}
	} else if provider.WalletAddress != "" {
		if err := s.ledger.CreditProvider(provider.WalletAddress, providerPayout, model, requestID); err != nil {
			s.logger.Error("failed to credit provider wallet for embedding/rerank",
				"provider_id", provider.ID,
				"wallet_address", provider.WalletAddress,
				"request_id", requestID,
				"error", err,
			)
		}
	}

	platformFee := payments.PlatformFee(totalCost)
	if platformFee > 0 {
		if s.billing != nil && s.billing.Referral() != nil {
			platformFee = s.billing.Referral().DistributeReferralReward(pr.ConsumerKey, platformFee, requestID)
		}
		_ = s.store.Credit("platform", platformFee, store.LedgerPlatformFee, requestID)
	}
}

// formatEmbeddingData returns the OpenAI-shaped data list. We always emit
// float arrays — the handler rejects encoding_format=base64 up front.
func formatEmbeddingData(vectors []protocol.EmbeddingVector) []map[string]any {
	out := make([]map[string]any, 0, len(vectors))
	for _, v := range vectors {
		out = append(out, map[string]any{
			"object":    "embedding",
			"index":     v.Index,
			"embedding": v.Embedding,
		})
	}
	return out
}

// handleEmbeddingComplete forwards an embedding result from a provider's
// websocket loop to the waiting consumer handler.
func (s *Server) handleEmbeddingComplete(providerID string, provider *registry.Provider, msg *protocol.EmbeddingCompleteMessage) {
	if provider == nil {
		s.logger.Warn("embedding complete from unregistered provider", "provider_id", providerID)
		return
	}
	pr := provider.RemovePending(msg.RequestID)
	if pr == nil {
		s.logger.Warn("embedding complete for unknown request",
			"provider_id", providerID, "request_id", msg.RequestID)
		return
	}
	if pr.EmbeddingCh != nil {
		select {
		case pr.EmbeddingCh <- msg:
		default:
			s.logger.Warn("dropped embedding result, consumer channel full",
				"request_id", msg.RequestID)
		}
	}
}

// handleRerankComplete forwards a rerank result from a provider's websocket
// loop to the waiting consumer handler.
func (s *Server) handleRerankComplete(providerID string, provider *registry.Provider, msg *protocol.RerankCompleteMessage) {
	if provider == nil {
		s.logger.Warn("rerank complete from unregistered provider", "provider_id", providerID)
		return
	}
	pr := provider.RemovePending(msg.RequestID)
	if pr == nil {
		s.logger.Warn("rerank complete for unknown request",
			"provider_id", providerID, "request_id", msg.RequestID)
		return
	}
	if pr.RerankCh != nil {
		select {
		case pr.RerankCh <- msg:
		default:
			s.logger.Warn("dropped rerank result, consumer channel full",
				"request_id", msg.RequestID)
		}
	}
}
