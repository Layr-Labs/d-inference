package api

// Smart-prefill prompt compression — POST /v1/compress.
//
// A small-tier provider runs a tiny draft LLM (e.g. Qwen3-0.6B), captures
// per-token attention scores over the consumer's prompt, and returns the
// top-K% of tokens in order. The coordinator either:
//
//   * returns the compressed prompt directly (this endpoint), or
//   * swaps it into a chat-completion request before dispatching to the
//     big-tier model (smart_prefill middleware in consumer.go).
//
// Either way the consumer's big-tier prefill cost drops by 2-5x at
// >90% task quality. See docs/smart-prefill.md for the full design.
//
// Architecture, billing, refund-on-error, retry, E2E encryption, and
// tier preference all mirror /v1/embeddings — see embeddings.go for the
// canonical pattern. This file is intentionally a thin reuse.

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
	// compressionTimeout — compression on a 0.6B draft is single-pass and
	// fast (<5s for 32k tokens on M2 Air per vllm-mlx#179 numbers); 60s
	// covers cold-start of the draft model.
	compressionTimeout = 60 * time.Second

	// defaultCompressorModel is what the smart-prefill middleware uses
	// when the consumer doesn't specify one. Qwen3-0.6B is small enough
	// for a 8 GB Air and works as a cross-family draft for every model
	// in the big-tier catalog (cross-family draft validity from
	// arXiv 2603.02631).
	defaultCompressorModel = "mlx-community/Qwen3-0.6B"

	// defaultCompressionRatio is 0.25 = 4x compression. The cited
	// research consistently shows >90% LongBench quality at 4x; below
	// that the big-tier model loses too much context.
	defaultCompressionRatio = 0.25
)

// compressionMaxAttempts mirrors embeddingMaxAttempts (3) so a single
// flaky compressor doesn't 502 the consumer.
const compressionMaxAttempts = 3

// handleCompress handles POST /v1/compress.
//
// Request body:
//
//	{ "prompt": "...", "compressor_model": "...", "target_ratio": 0.25, "min_keep_tokens": 64 }
//
// Returns:
//
//	{ "compressed_prompt": "...", "model": "...",
//	  "usage": { "original_tokens": 4096, "compressed_tokens": 1024 } }
func (s *Server) handleCompress(w http.ResponseWriter, r *http.Request) {
	rawBody, err := io.ReadAll(r.Body)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "failed to read request body"))
		return
	}
	var req protocol.PromptCompressionRequestBody
	if err := json.Unmarshal(rawBody, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.Prompt == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "prompt is required"))
		return
	}
	if req.CompressorModel == "" {
		req.CompressorModel = defaultCompressorModel
	}
	if req.TargetRatio == 0 {
		req.TargetRatio = defaultCompressionRatio
	}
	if req.TargetRatio <= 0 || req.TargetRatio > 1 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			"target_ratio must be in (0, 1]"))
		return
	}
	if !s.registry.IsModelInCatalog(req.CompressorModel) {
		writeJSON(w, http.StatusNotFound, errorResponse("model_not_found",
			fmt.Sprintf("compressor %q is not available — see /v1/models for supported models", req.CompressorModel)))
		return
	}

	consumerKey := consumerKeyFromContext(r.Context())
	estimatedTokens := approxTokens(req.Prompt)
	customRate, _, hasCustom := s.store.GetModelPrice("platform", req.CompressorModel)

	// Pre-flight reservation. As with embeddings/rerank, we only set
	// reservedMicroUSD when billing is wired up so the refund path can't
	// mint free credit on a billing-disabled deployment.
	var reservedMicroUSD int64
	if s.billing != nil {
		if hasCustom {
			reservedMicroUSD = int64(estimatedTokens) * customRate / 1_000_000
			if reservedMicroUSD < payments.MinimumCharge() {
				reservedMicroUSD = payments.MinimumCharge()
			}
		} else {
			reservedMicroUSD = payments.CalculateCompressorCost(req.CompressorModel, estimatedTokens)
		}
		if err := s.ledger.Charge(consumerKey, reservedMicroUSD, "reserve:"+consumerKey); err != nil {
			writeJSON(w, http.StatusPaymentRequired, errorResponse("insufficient_funds",
				"your balance is too low for this request — add funds at /billing"))
			return
		}
	}
	refund := func(amount int64) {
		if amount > 0 && s.billing != nil {
			_ = s.store.Credit(consumerKey, amount, store.LedgerRefund, "compression_refund")
		}
	}

	result, statusCode, errMsg := s.runCompression(r, &req, rawBody, consumerKey,
		estimatedTokens, reservedMicroUSD, customRate, hasCustom)
	if result == nil {
		refund(reservedMicroUSD)
		writeJSON(w, statusCode, errorResponse("provider_error", errMsg))
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"object":            "compression",
		"model":             req.CompressorModel,
		"compressed_prompt": result.CompressedPrompt,
		"usage": map[string]any{
			"original_tokens":   result.Usage.OriginalTokens,
			"compressed_tokens": result.Usage.CompressedTokens,
			"total_tokens":      result.Usage.TotalTokens,
			"ratio":             ratio(result.Usage),
		},
	})
}

func ratio(u protocol.PromptCompressionUsage) float64 {
	if u.OriginalTokens == 0 {
		return 1.0
	}
	return float64(u.CompressedTokens) / float64(u.OriginalTokens)
}

// runCompression handles dispatch + retry across providers and returns
// the decrypted result on success. On failure returns nil + a status code
// + an error message. Used by both the standalone /v1/compress endpoint
// and the smart-prefill middleware in consumer.go. rawBody is the
// already-marshaled compression request (we re-encrypt it per provider).
func (s *Server) runCompression(
	r *http.Request,
	req *protocol.PromptCompressionRequestBody,
	rawBody []byte,
	consumerKey string,
	estimatedTokens int,
	reservedMicroUSD int64,
	customRate int64,
	hasCustom bool,
) (*protocol.PromptCompressionCompleteMessage, int, string) {
	excludeProviders := make(map[string]struct{})
	excludeList := func() []string {
		ids := make([]string, 0, len(excludeProviders))
		for id := range excludeProviders {
			ids = append(ids, id)
		}
		return ids
	}

	ctx, cancel := context.WithTimeout(r.Context(), compressionTimeout)
	defer cancel()

	var (
		lastCode = http.StatusServiceUnavailable
		lastErr  = "no compressor provider available"
	)

	for attempt := 0; attempt < compressionMaxAttempts; attempt++ {
		requestID := uuid.New().String()
		pr := &registry.PendingRequest{
			RequestID:             requestID,
			Model:                 req.CompressorModel,
			ConsumerKey:           consumerKey,
			EstimatedPromptTokens: estimatedTokens,
			RequestedMaxTokens:    1,
			ReservedMicroUSD:      reservedMicroUSD,
			ChunkCh:               make(chan string, 1),
			CompleteCh:            make(chan protocol.UsageInfo, 1),
			ErrorCh:               make(chan protocol.InferenceErrorMessage, 1),
			CompressionCh:         make(chan *protocol.PromptCompressionCompleteMessage, 1),
		}

		provider := s.registry.ReserveProvider(req.CompressorModel, pr, excludeList()...)
		if provider == nil {
			break
		}

		ok, errMsg, errCode, result := s.dispatchCompression(ctx, r, req.CompressorModel, rawBody, requestID, provider, pr)
		if !ok {
			excludeProviders[provider.ID] = struct{}{}
			lastErr = errMsg
			if errCode != 0 {
				lastCode = errCode
			}
			continue
		}

		// Success — clamp & refund.
		actualTokens := int(result.Usage.OriginalTokens)
		if actualTokens <= 0 {
			actualTokens = estimatedTokens
		}
		actualCost := computeCompressorCost(req.CompressorModel, actualTokens, customRate, hasCustom)
		if reservedMicroUSD > 0 {
			if actualCost > reservedMicroUSD {
				s.logger.Error("compression provider over-reported usage — clamping",
					"provider_id", provider.ID, "request_id", requestID,
					"actual_cost", actualCost, "reserved", reservedMicroUSD)
				actualCost = reservedMicroUSD
			}
			if actualCost < reservedMicroUSD {
				if amount := reservedMicroUSD - actualCost; amount > 0 && s.billing != nil {
					_ = s.store.Credit(consumerKey, amount, store.LedgerRefund, "compression_refund")
				}
			}
		}

		s.recordDisaggregatedBilling(provider, pr, requestID, req.CompressorModel, actualTokens, actualCost, result.DurationSecs)
		return result, http.StatusOK, ""
	}

	return nil, lastCode, fmt.Sprintf("compression failed after %d attempt(s): %s", compressionMaxAttempts, lastErr)
}

// dispatchCompression sends one compression attempt to a reserved provider.
// On every exit path it cleans up the pending request and the provider's
// serving state.
func (s *Server) dispatchCompression(
	ctx context.Context,
	r *http.Request,
	model string,
	rawBody []byte,
	requestID string,
	provider *registry.Provider,
	pr *registry.PendingRequest,
) (bool, string, int, *protocol.PromptCompressionCompleteMessage) {
	cleanup := func() {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
	}
	if provider.PublicKey == "" {
		cleanup()
		return false, "no provider with E2E encryption available", 0, nil
	}
	pubKey, err := e2e.ParsePublicKey(provider.PublicKey)
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

	encrypted, err := e2e.Encrypt(rawBody, pubKey, sessionKeys)
	if err != nil {
		cleanup()
		return false, "failed to encrypt request", 0, nil
	}

	wireMsg := map[string]any{
		"type":       protocol.TypePromptCompressionRequest,
		"request_id": requestID,
		"encrypted_body": map[string]string{
			"ephemeral_public_key": encrypted.EphemeralPublicKey,
			"ciphertext":           encrypted.Ciphertext,
		},
	}
	data, _ := json.Marshal(wireMsg)
	if err := provider.Conn.Write(r.Context(), websocket.MessageText, data); err != nil {
		cleanup()
		s.logger.Error("failed to send compression request",
			"request_id", requestID, "provider_id", provider.ID, "error", err)
		return false, "failed to send request to provider", 0, nil
	}

	s.logger.Info("compression request dispatched",
		"request_id", requestID,
		"compressor", model,
		"provider_id", provider.ID,
		"provider_tier", provider.Tier,
		"estimated_tokens", pr.EstimatedPromptTokens,
	)

	select {
	case result := <-pr.CompressionCh:
		s.registry.SetProviderIdle(provider.ID)
		if result == nil {
			return false, "compressor closed channel", 0, nil
		}
		if result.EncryptedData != nil {
			payload := &e2e.EncryptedPayload{
				EphemeralPublicKey: result.EncryptedData.EphemeralPublicKey,
				Ciphertext:         result.EncryptedData.Ciphertext,
			}
			plaintext, derr := e2e.DecryptWithPrivateKey(payload, sessionKeys.PrivateKey)
			if derr != nil {
				s.registry.RecordJobFailure(provider.ID)
				return false, "failed to decrypt compression response: " + derr.Error(), http.StatusBadGateway, nil
			}
			result.CompressedPrompt = string(plaintext)
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
		return false, "compression timed out", http.StatusGatewayTimeout, nil
	}
}

func computeCompressorCost(model string, tokens int, customRate int64, hasCustom bool) int64 {
	if hasCustom {
		cost := int64(tokens) * customRate / 1_000_000
		if cost < payments.MinimumCharge() {
			cost = payments.MinimumCharge()
		}
		return cost
	}
	return payments.CalculateCompressorCost(model, tokens)
}

// handlePromptCompressionComplete forwards a compression result from a
// provider's websocket loop to the waiting consumer handler.
func (s *Server) handlePromptCompressionComplete(providerID string, provider *registry.Provider, msg *protocol.PromptCompressionCompleteMessage) {
	if provider == nil {
		s.logger.Warn("compression complete from unregistered provider", "provider_id", providerID)
		return
	}
	pr := provider.RemovePending(msg.RequestID)
	if pr == nil {
		s.logger.Warn("compression complete for unknown request",
			"provider_id", providerID, "request_id", msg.RequestID)
		return
	}
	if pr.CompressionCh != nil {
		select {
		case pr.CompressionCh <- msg:
		default:
			s.logger.Warn("dropped compression result, consumer channel full",
				"request_id", msg.RequestID)
		}
	}
}
