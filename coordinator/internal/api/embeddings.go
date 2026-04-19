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
)

// embeddingChannelChunkBuffer is reused for the small set of channels we
// allocate per embedding/rerank request — small because nothing streams.
const embeddingChannelChunkBuffer = 1

// estimateEmbeddingPromptTokens returns an approximate token count for an
// embedding request body. The `input` field is a JSON value that is either
// a string or an array of strings; we approximate ~4 chars per token.
func estimateEmbeddingPromptTokens(input json.RawMessage) int {
	if len(input) == 0 {
		return 0
	}
	// Try string first.
	var s string
	if err := json.Unmarshal(input, &s); err == nil {
		return approxTokens(s)
	}
	// Try array of strings.
	var arr []string
	if err := json.Unmarshal(input, &arr); err == nil {
		total := 0
		for _, item := range arr {
			total += approxTokens(item)
		}
		return total
	}
	// Try array of token-id arrays (OpenAI accepts these too).
	var tokenArrays [][]int
	if err := json.Unmarshal(input, &tokenArrays); err == nil {
		total := 0
		for _, item := range tokenArrays {
			total += len(item)
		}
		return total
	}
	// Fall back to byte length / 4.
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
// (query, document) pairs.
func estimateRerankPromptTokens(query string, documents []string) int {
	queryTokens := approxTokens(query)
	total := 0
	for _, d := range documents {
		// Each pair = query + document for a cross-encoder.
		total += queryTokens + approxTokens(d)
	}
	return total
}

// handleEmbeddings handles POST /v1/embeddings.
//
// The request body matches OpenAI's /v1/embeddings:
//
//	{ "model": "...", "input": "..." | ["..."], "encoding_format": "float"|"base64", "dimensions": int? }
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
	if !s.registry.IsModelInCatalog(req.Model) {
		writeJSON(w, http.StatusNotFound, errorResponse("model_not_found",
			fmt.Sprintf("model %q is not available — see /v1/models for supported models", req.Model)))
		return
	}

	consumerKey := consumerKeyFromContext(r.Context())
	estimatedTokens := estimateEmbeddingPromptTokens(req.Input)

	// Pre-flight billing reservation. The post-inference charge refunds the
	// difference between the actual and reserved amount. For embeddings the
	// estimate is usually accurate (no generation phase), so the refund is
	// typically zero, but keeping the reservation pattern means a free
	// inference is impossible if the provider over-reports usage.
	customRate, _, hasCustom := s.store.GetModelPrice("platform", req.Model)
	var reservedMicroUSD int64
	if hasCustom {
		reservedMicroUSD = int64(estimatedTokens) * customRate / 1_000_000
		if reservedMicroUSD < payments.MinimumCharge() {
			reservedMicroUSD = payments.MinimumCharge()
		}
	} else {
		reservedMicroUSD = payments.CalculateEmbeddingCost(req.Model, estimatedTokens)
	}

	if s.billing != nil {
		if err := s.ledger.Charge(consumerKey, reservedMicroUSD, "reserve:"+consumerKey); err != nil {
			writeJSON(w, http.StatusPaymentRequired, errorResponse("insufficient_funds",
				"your balance is too low for this request — add funds at /billing"))
			return
		}
	}

	refund := func(amount int64) {
		if amount > 0 {
			_ = s.store.Credit(consumerKey, amount, store.LedgerRefund, "embedding_refund")
		}
	}

	requestID := uuid.New().String()
	pr := &registry.PendingRequest{
		RequestID:             requestID,
		Model:                 req.Model,
		ConsumerKey:           consumerKey,
		EstimatedPromptTokens: estimatedTokens,
		RequestedMaxTokens:    1, // embeddings produce no completion tokens; small bias for scheduler
		ReservedMicroUSD:      reservedMicroUSD,
		ChunkCh:               make(chan string, embeddingChannelChunkBuffer),
		CompleteCh:            make(chan protocol.UsageInfo, 1),
		ErrorCh:               make(chan protocol.InferenceErrorMessage, 1),
		EmbeddingCh:           make(chan *protocol.EmbeddingCompleteMessage, 1),
	}

	provider := s.registry.ReserveProvider(req.Model, pr)
	if provider == nil {
		refund(reservedMicroUSD)
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_not_available",
			fmt.Sprintf("no provider available for embedding model %q", req.Model)))
		return
	}

	// E2E encryption is mandatory: even short query text can be sensitive
	// (medical, legal, financial). The coordinator never sees plaintext.
	if provider.PublicKey == "" {
		s.registry.SetProviderIdle(provider.ID)
		refund(reservedMicroUSD)
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("encryption_required",
			"no provider with E2E encryption available for this model"))
		return
	}

	providerPubKey, err := e2e.ParsePublicKey(provider.PublicKey)
	if err != nil {
		s.registry.SetProviderIdle(provider.ID)
		refund(reservedMicroUSD)
		writeJSON(w, http.StatusInternalServerError, errorResponse("encryption_error", "provider public key invalid"))
		return
	}

	sessionKeys, err := e2e.GenerateSessionKeys()
	if err != nil {
		s.registry.SetProviderIdle(provider.ID)
		refund(reservedMicroUSD)
		writeJSON(w, http.StatusInternalServerError, errorResponse("encryption_error", "failed to generate session keys"))
		return
	}

	encrypted, err := e2e.Encrypt(rawBody, providerPubKey, sessionKeys)
	if err != nil {
		s.registry.SetProviderIdle(provider.ID)
		refund(reservedMicroUSD)
		writeJSON(w, http.StatusInternalServerError, errorResponse("encryption_error", "failed to encrypt request"))
		return
	}

	wireMsg := map[string]any{
		"type":       protocol.TypeEmbeddingRequest,
		"request_id": requestID,
		"encrypted_body": map[string]string{
			"ephemeral_public_key": encrypted.EphemeralPublicKey,
			"ciphertext":           encrypted.Ciphertext,
		},
	}
	pr.SessionPrivKey = &sessionKeys.PrivateKey

	data, _ := json.Marshal(wireMsg)
	if err := provider.Conn.Write(r.Context(), websocket.MessageText, data); err != nil {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		refund(reservedMicroUSD)
		writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "failed to send request to provider"))
		return
	}

	defer func() {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
	}()

	s.logger.Info("embedding request dispatched",
		"request_id", requestID,
		"model", req.Model,
		"provider_id", provider.ID,
		"provider_tier", provider.Tier,
		"estimated_tokens", estimatedTokens,
	)

	ctx, cancel := context.WithTimeout(r.Context(), embeddingTimeout)
	defer cancel()

	select {
	case result := <-pr.EmbeddingCh:
		if result == nil {
			refund(reservedMicroUSD)
			writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "embedding provider closed channel"))
			return
		}
		// If the provider returned an encrypted payload, decrypt it now.
		// (E2E was used on the request → the provider may also encrypt the
		// response payload back to us using the session key.)
		dataVectors := result.Data
		if result.EncryptedData != nil && pr.SessionPrivKey != nil {
			payload := &e2e.EncryptedPayload{
				EphemeralPublicKey: result.EncryptedData.EphemeralPublicKey,
				Ciphertext:         result.EncryptedData.Ciphertext,
			}
			plaintext, err := e2e.DecryptWithPrivateKey(payload, *pr.SessionPrivKey)
			if err != nil {
				refund(reservedMicroUSD)
				writeJSON(w, http.StatusBadGateway, errorResponse("provider_error",
					"failed to decrypt embedding response: "+err.Error()))
				return
			}
			if err := json.Unmarshal(plaintext, &dataVectors); err != nil {
				refund(reservedMicroUSD)
				writeJSON(w, http.StatusBadGateway, errorResponse("provider_error",
					"invalid encrypted embedding response: "+err.Error()))
				return
			}
		}

		// Compute the actual cost from reported usage and refund the
		// difference. Clamp to the reservation so a misbehaving provider
		// can never overcharge.
		actualTokens := result.Usage.PromptTokens
		if actualTokens <= 0 {
			actualTokens = estimatedTokens
		}
		actualCost := payments.CalculateEmbeddingCost(req.Model, actualTokens)
		if hasCustom {
			actualCost = int64(actualTokens) * customRate / 1_000_000
			if actualCost < payments.MinimumCharge() {
				actualCost = payments.MinimumCharge()
			}
		}
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

		s.recordEmbeddingBilling(provider, pr, requestID, req.Model, actualTokens, actualCost)

		// Build OpenAI-compatible response.
		out := map[string]any{
			"object": "list",
			"model":  req.Model,
			"data":   formatEmbeddingData(dataVectors, req.EncodingFormat),
			"usage": map[string]any{
				"prompt_tokens": actualTokens,
				"total_tokens":  actualTokens,
			},
		}
		writeJSON(w, http.StatusOK, out)

	case errMsg := <-pr.ErrorCh:
		refund(reservedMicroUSD)
		statusCode := errMsg.StatusCode
		if statusCode == 0 {
			statusCode = http.StatusBadGateway
		}
		writeJSON(w, statusCode, errorResponse("provider_error", errMsg.Error))

	case <-ctx.Done():
		refund(reservedMicroUSD)
		writeJSON(w, http.StatusGatewayTimeout, errorResponse("timeout", "embedding request timed out"))
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
	if hasCustom {
		reservedMicroUSD = int64(estimatedTokens) * customRate / 1_000_000
		if reservedMicroUSD < payments.MinimumCharge() {
			reservedMicroUSD = payments.MinimumCharge()
		}
	} else {
		reservedMicroUSD = payments.CalculateRerankCost(req.Model, estimatedTokens)
	}

	if s.billing != nil {
		if err := s.ledger.Charge(consumerKey, reservedMicroUSD, "reserve:"+consumerKey); err != nil {
			writeJSON(w, http.StatusPaymentRequired, errorResponse("insufficient_funds",
				"your balance is too low for this request — add funds at /billing"))
			return
		}
	}

	refund := func(amount int64) {
		if amount > 0 {
			_ = s.store.Credit(consumerKey, amount, store.LedgerRefund, "rerank_refund")
		}
	}

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

	provider := s.registry.ReserveProvider(req.Model, pr)
	if provider == nil {
		refund(reservedMicroUSD)
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_not_available",
			fmt.Sprintf("no provider available for rerank model %q", req.Model)))
		return
	}

	if provider.PublicKey == "" {
		s.registry.SetProviderIdle(provider.ID)
		refund(reservedMicroUSD)
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("encryption_required",
			"no provider with E2E encryption available for this model"))
		return
	}

	providerPubKey, err := e2e.ParsePublicKey(provider.PublicKey)
	if err != nil {
		s.registry.SetProviderIdle(provider.ID)
		refund(reservedMicroUSD)
		writeJSON(w, http.StatusInternalServerError, errorResponse("encryption_error", "provider public key invalid"))
		return
	}

	sessionKeys, err := e2e.GenerateSessionKeys()
	if err != nil {
		s.registry.SetProviderIdle(provider.ID)
		refund(reservedMicroUSD)
		writeJSON(w, http.StatusInternalServerError, errorResponse("encryption_error", "failed to generate session keys"))
		return
	}

	encrypted, err := e2e.Encrypt(rawBody, providerPubKey, sessionKeys)
	if err != nil {
		s.registry.SetProviderIdle(provider.ID)
		refund(reservedMicroUSD)
		writeJSON(w, http.StatusInternalServerError, errorResponse("encryption_error", "failed to encrypt request"))
		return
	}

	wireMsg := map[string]any{
		"type":       protocol.TypeRerankRequest,
		"request_id": requestID,
		"encrypted_body": map[string]string{
			"ephemeral_public_key": encrypted.EphemeralPublicKey,
			"ciphertext":           encrypted.Ciphertext,
		},
	}
	pr.SessionPrivKey = &sessionKeys.PrivateKey

	data, _ := json.Marshal(wireMsg)
	if err := provider.Conn.Write(r.Context(), websocket.MessageText, data); err != nil {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		refund(reservedMicroUSD)
		writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "failed to send request to provider"))
		return
	}

	defer func() {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
	}()

	s.logger.Info("rerank request dispatched",
		"request_id", requestID,
		"model", req.Model,
		"provider_id", provider.ID,
		"provider_tier", provider.Tier,
		"estimated_tokens", estimatedTokens,
		"document_count", len(req.Documents),
	)

	ctx, cancel := context.WithTimeout(r.Context(), embeddingTimeout)
	defer cancel()

	select {
	case result := <-pr.RerankCh:
		if result == nil {
			refund(reservedMicroUSD)
			writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "rerank provider closed channel"))
			return
		}
		results := result.Results
		if result.EncryptedData != nil && pr.SessionPrivKey != nil {
			payload := &e2e.EncryptedPayload{
				EphemeralPublicKey: result.EncryptedData.EphemeralPublicKey,
				Ciphertext:         result.EncryptedData.Ciphertext,
			}
			plaintext, err := e2e.DecryptWithPrivateKey(payload, *pr.SessionPrivKey)
			if err != nil {
				refund(reservedMicroUSD)
				writeJSON(w, http.StatusBadGateway, errorResponse("provider_error",
					"failed to decrypt rerank response: "+err.Error()))
				return
			}
			if err := json.Unmarshal(plaintext, &results); err != nil {
				refund(reservedMicroUSD)
				writeJSON(w, http.StatusBadGateway, errorResponse("provider_error",
					"invalid encrypted rerank response: "+err.Error()))
				return
			}
		}

		// Apply top_n trimming on the coordinator if the provider didn't.
		if req.TopN != nil && *req.TopN > 0 && len(results) > *req.TopN {
			results = results[:*req.TopN]
		}

		actualTokens := result.Usage.PromptTokens
		if actualTokens <= 0 {
			actualTokens = estimatedTokens
		}
		actualCost := payments.CalculateRerankCost(req.Model, actualTokens)
		if hasCustom {
			actualCost = int64(actualTokens) * customRate / 1_000_000
			if actualCost < payments.MinimumCharge() {
				actualCost = payments.MinimumCharge()
			}
		}
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

		s.recordEmbeddingBilling(provider, pr, requestID, req.Model, actualTokens, actualCost)

		writeJSON(w, http.StatusOK, map[string]any{
			"id":      "rerank-" + requestID,
			"model":   req.Model,
			"results": results,
			"usage": map[string]any{
				"prompt_tokens": actualTokens,
				"total_tokens":  actualTokens,
			},
		})

	case errMsg := <-pr.ErrorCh:
		refund(reservedMicroUSD)
		statusCode := errMsg.StatusCode
		if statusCode == 0 {
			statusCode = http.StatusBadGateway
		}
		writeJSON(w, statusCode, errorResponse("provider_error", errMsg.Error))

	case <-ctx.Done():
		refund(reservedMicroUSD)
		writeJSON(w, http.StatusGatewayTimeout, errorResponse("timeout", "rerank request timed out"))
	}
}

// recordEmbeddingBilling records usage + provider payout for an embedding
// or rerank job. Same shape as the chat-completions billing path so admin
// dashboards see uniform data.
func (s *Server) recordEmbeddingBilling(provider *registry.Provider, pr *registry.PendingRequest, requestID, model string, tokens int, totalCost int64) {
	providerPayout := payments.ProviderPayout(totalCost)

	s.ledger.RecordUsage(pr.ConsumerKey, payments.UsageEntry{
		JobID:        requestID,
		Model:        model,
		PromptTokens: tokens,
		CostMicroUSD: totalCost,
		Timestamp:    time.Now(),
	})
	s.store.RecordUsageWithCost(provider.ID, pr.ConsumerKey, model, requestID, tokens, 0, totalCost)

	// Record the job success (for reputation / heartbeat stats).
	s.registry.RecordJobSuccess(provider.ID, time.Duration(tokens)*time.Microsecond)

	// Provider payout — same path as chat completions.
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

// formatEmbeddingData returns the OpenAI-shaped data list. We default to
// "float" arrays — base64 encoding can be added if/when consumers ask.
func formatEmbeddingData(vectors []protocol.EmbeddingVector, encodingFormat string) []map[string]any {
	out := make([]map[string]any, 0, len(vectors))
	for _, v := range vectors {
		entry := map[string]any{
			"object":    "embedding",
			"index":     v.Index,
			"embedding": v.Embedding,
		}
		out = append(out, entry)
	}
	_ = encodingFormat
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
