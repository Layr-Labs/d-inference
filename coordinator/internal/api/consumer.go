package api

// Consumer-facing API handlers for the DGInf coordinator.
//
// This file implements the OpenAI-compatible HTTP endpoints that consumers
// use to send inference requests. The coordinator acts as a trusted routing
// layer between consumers and providers.
//
// Trust model:
//   The coordinator runs in a GCP Confidential VM with AMD SEV-SNP, providing
//   hardware-encrypted memory. Consumer traffic arrives over HTTPS/TLS.
//   The coordinator can read requests for routing purposes but never logs
//   prompt content. When forwarding to a provider, the coordinator sends
//   plain JSON over the WebSocket (the provider is attested via Secure Enclave
//   challenge-response). Future: the coordinator may encrypt request bodies
//   with the provider's X25519 public key before forwarding.

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/dginf/coordinator/internal/protocol"
	"github.com/dginf/coordinator/internal/registry"
	"github.com/google/uuid"
	"nhooyr.io/websocket"
)

const (
	// inferenceTimeout is the maximum time to wait for a provider to complete
	// an inference request before timing out the consumer's HTTP response.
	inferenceTimeout = 30 * time.Second

	// chunkBufferSize is the channel buffer size for SSE chunks flowing from
	// the provider to the consumer. A larger buffer prevents dropped chunks
	// when the consumer reads slowly.
	chunkBufferSize = 256
)

// chatCompletionRequest is the incoming OpenAI-compatible request body.
// The consumer sends plain JSON — no encryption fields are needed because
// TLS to the Confidential VM is the trust boundary.
type chatCompletionRequest struct {
	Model    string                 `json:"model"`
	Messages []protocol.ChatMessage `json:"messages"`
	Stream   bool                   `json:"stream"`
}

// handleChatCompletions handles POST /v1/chat/completions.
//
// This is the main inference endpoint. It validates the request, finds an
// available provider for the requested model, forwards the request via
// WebSocket, and either streams SSE chunks or assembles a complete response.
func (s *Server) handleChatCompletions(w http.ResponseWriter, r *http.Request) {
	// Decode request body.
	var req chatCompletionRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}

	if req.Model == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "model is required"))
		return
	}

	if len(req.Messages) == 0 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "messages is required and must be non-empty"))
		return
	}

	// Find a provider that serves the requested model. The registry uses
	// round-robin among idle providers with the model loaded.
	provider := s.registry.FindProvider(req.Model)
	if provider == nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_not_available", fmt.Sprintf("no provider available for model %q", req.Model)))
		return
	}

	// Build the inference request to forward to the provider.
	// The body is plain JSON — the coordinator can read it for routing.
	// Prompt content is never logged.
	requestID := uuid.New().String()

	plainBody := protocol.InferenceRequestBody{
		Model:    req.Model,
		Messages: req.Messages,
		Stream:   req.Stream,
	}
	inferenceBody, _ := json.Marshal(plainBody)

	// Build the wire message with raw JSON body
	wireMsg := map[string]any{
		"type":       protocol.TypeInferenceRequest,
		"request_id": requestID,
		"body":       json.RawMessage(inferenceBody),
	}

	// Create pending request channels. These channels connect the provider's
	// WebSocket read loop to this HTTP handler, allowing chunks to flow from
	// provider -> coordinator -> consumer in real time.
	consumerKey := consumerKeyFromContext(r.Context())
	pr := &registry.PendingRequest{
		RequestID:   requestID,
		ProviderID:  provider.ID,
		Model:       req.Model,
		ConsumerKey: consumerKey,
		ChunkCh:     make(chan string, chunkBufferSize),
		CompleteCh:  make(chan protocol.UsageInfo, 1),
		ErrorCh:     make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)

	// Send the inference request to the provider via WebSocket.
	data, err := json.Marshal(wireMsg)
	if err != nil {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to marshal request"))
		return
	}
	if err := provider.Conn.Write(r.Context(), websocket.MessageText, data); err != nil {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.logger.Error("failed to send inference request", "request_id", requestID, "error", err)
		writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "failed to send request to provider"))
		return
	}

	s.logger.Info("inference request dispatched",
		"request_id", requestID,
		"model", req.Model,
		"provider_id", provider.ID,
		"stream", req.Stream,
	)

	// Include provider's public key in response headers so consumers can
	// see which provider key was used (useful for auditing).
	if provider.PublicKey != "" {
		w.Header().Set("X-Provider-Public-Key", provider.PublicKey)
	}

	// Include attestation status headers so consumers know the trust
	// properties of the provider that served their request.
	if provider.Attested {
		w.Header().Set("X-Provider-Attested", "true")
	} else {
		w.Header().Set("X-Provider-Attested", "false")
	}
	w.Header().Set("X-Provider-Trust-Level", string(provider.TrustLevel))
	if provider.AttestationResult != nil {
		if provider.AttestationResult.SecureEnclaveAvailable {
			w.Header().Set("X-Provider-Secure-Enclave", "true")
		} else {
			w.Header().Set("X-Provider-Secure-Enclave", "false")
		}
	}

	if req.Stream {
		s.handleStreamingResponse(w, r, pr)
	} else {
		s.handleNonStreamingResponse(w, r, pr)
	}
}

// handleStreamingResponse writes SSE events to the consumer as they arrive
// from the provider. Each chunk is forwarded in real time, providing
// token-by-token streaming to the consumer.
func (s *Server) handleStreamingResponse(w http.ResponseWriter, r *http.Request, pr *registry.PendingRequest) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "streaming not supported"))
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Request-ID", pr.RequestID)
	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	ctx, cancel := context.WithTimeout(r.Context(), inferenceTimeout)
	defer cancel()

	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if !ok {
				// Channel closed — inference complete.
				fmt.Fprint(w, "data: [DONE]\n\n")
				flusher.Flush()
				return
			}
			// The chunk data from the provider already includes the "data: ..." SSE format.
			fmt.Fprint(w, chunk)
			flusher.Flush()

		case errMsg := <-pr.ErrorCh:
			// Write error as SSE event so the consumer can handle it gracefully.
			errData, _ := json.Marshal(map[string]any{
				"error": map[string]any{
					"message": errMsg.Error,
					"type":    "provider_error",
				},
			})
			fmt.Fprintf(w, "data: %s\n\n", errData)
			flusher.Flush()
			return

		case <-ctx.Done():
			fmt.Fprintf(w, "data: {\"error\":{\"message\":\"request timed out\",\"type\":\"timeout\"}}\n\n")
			flusher.Flush()
			return
		}
	}
}

// handleNonStreamingResponse collects all chunks from the provider and
// assembles them into a single complete OpenAI-compatible JSON response.
// This is used when the consumer sets stream=false.
func (s *Server) handleNonStreamingResponse(w http.ResponseWriter, r *http.Request, pr *registry.PendingRequest) {
	ctx, cancel := context.WithTimeout(r.Context(), inferenceTimeout)
	defer cancel()

	var chunks []string

	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if !ok {
				// Complete — build aggregated response from all collected chunks.
				content := extractContent(chunks)
				// Wait for usage info from the provider's InferenceComplete message.
				select {
				case usage := <-pr.CompleteCh:
					resp := buildNonStreamingResponse(pr.RequestID, pr.Model, content, usage)
					writeJSON(w, http.StatusOK, resp)
				case <-ctx.Done():
					writeJSON(w, http.StatusGatewayTimeout, errorResponse("timeout", "timed out waiting for usage info"))
				}
				return
			}
			chunks = append(chunks, chunk)

		case errMsg := <-pr.ErrorCh:
			statusCode := errMsg.StatusCode
			if statusCode == 0 {
				statusCode = http.StatusBadGateway
			}
			writeJSON(w, statusCode, errorResponse("provider_error", errMsg.Error))
			return

		case <-ctx.Done():
			writeJSON(w, http.StatusGatewayTimeout, errorResponse("timeout", "request timed out"))
			return
		}
	}
}

// extractContent parses SSE data lines and concatenates delta content
// to reconstruct the full assistant message from streaming chunks.
func extractContent(chunks []string) string {
	var sb strings.Builder
	for _, chunk := range chunks {
		// Each chunk is "data: {...}\n\n"; parse the JSON.
		line := strings.TrimPrefix(chunk, "data: ")
		line = strings.TrimSpace(line)
		if line == "" || line == "[DONE]" {
			continue
		}

		var parsed struct {
			Choices []struct {
				Delta struct {
					Content string `json:"content"`
				} `json:"delta"`
			} `json:"choices"`
		}
		if err := json.Unmarshal([]byte(line), &parsed); err != nil {
			continue
		}
		for _, c := range parsed.Choices {
			sb.WriteString(c.Delta.Content)
		}
	}
	return sb.String()
}

// buildNonStreamingResponse constructs a complete OpenAI-compatible chat
// completion response from the aggregated content and usage info.
func buildNonStreamingResponse(requestID, model, content string, usage protocol.UsageInfo) map[string]any {
	return map[string]any{
		"id":      "chatcmpl-" + requestID,
		"object":  "chat.completion",
		"created": time.Now().Unix(),
		"model":   model,
		"choices": []map[string]any{
			{
				"index": 0,
				"message": map[string]any{
					"role":    "assistant",
					"content": content,
				},
				"finish_reason": "stop",
			},
		},
		"usage": map[string]any{
			"prompt_tokens":     usage.PromptTokens,
			"completion_tokens": usage.CompletionTokens,
			"total_tokens":      usage.PromptTokens + usage.CompletionTokens,
		},
	}
}

// handleListModels handles GET /v1/models.
//
// Returns a deduplicated list of models across all connected providers,
// including attestation metadata (trust level, Secure Enclave status,
// provider count) for each model.
func (s *Server) handleListModels(w http.ResponseWriter, r *http.Request) {
	models := s.registry.ListModels()

	data := make([]map[string]any, 0, len(models))
	for _, m := range models {
		metadata := map[string]any{
			"model_type":         m.ModelType,
			"quantization":       m.Quantization,
			"provider_count":     m.Providers,
			"attested_providers": m.AttestedProviders,
			"trust_level":        string(m.TrustLevel),
		}
		if m.Attestation != nil {
			metadata["attestation"] = map[string]any{
				"secure_enclave": m.Attestation.SecureEnclave,
				"sip_enabled":    m.Attestation.SIPEnabled,
				"secure_boot":    m.Attestation.SecureBoot,
			}
		}
		data = append(data, map[string]any{
			"id":       m.ID,
			"object":   "model",
			"created":  0,
			"owned_by": "dginf",
			"metadata": metadata,
		})
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"object": "list",
		"data":   data,
	})
}

// handleCreateKey handles POST /v1/auth/keys — creates a new consumer API key.
// This is an admin endpoint used for bootstrapping new consumers.
func (s *Server) handleCreateKey(w http.ResponseWriter, r *http.Request) {
	key, err := s.store.CreateKey()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("server_error", "failed to create key"))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"api_key": key})
}

// handleHealth handles GET /health.
// Returns the coordinator's status and the number of connected providers.
// This endpoint does not require authentication.
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"status":    "ok",
		"providers": s.registry.ProviderCount(),
	})
}

// --- payment handlers ---

// depositRequest is the JSON body for POST /v1/payments/deposit.
type depositRequest struct {
	WalletAddress string `json:"wallet_address"`
	AmountUSD     string `json:"amount_usd"`
}

// handleDeposit handles POST /v1/payments/deposit.
//
// For MVP this is trust-based — no on-chain verification. In production,
// the coordinator would verify an on-chain pathUSD transfer on the Tempo
// blockchain (via Viem's transferWithMemo) before crediting the ledger.
func (s *Server) handleDeposit(w http.ResponseWriter, r *http.Request) {
	var req depositRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}

	if req.WalletAddress == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "wallet_address is required"))
		return
	}
	if req.AmountUSD == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "amount_usd is required"))
		return
	}

	// Parse amount as float and convert to micro-USD (1 USD = 1,000,000 micro-USD).
	amountFloat, err := strconv.ParseFloat(req.AmountUSD, 64)
	if err != nil || amountFloat <= 0 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "amount_usd must be a positive number"))
		return
	}

	amountMicroUSD := int64(amountFloat * 1_000_000)

	// Credit the consumer's balance using their API key as the consumer ID.
	consumerKey := consumerKeyFromContext(r.Context())
	if err := s.ledger.Deposit(consumerKey, amountMicroUSD); err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to credit balance"))
		return
	}

	s.logger.Info("deposit credited",
		"consumer_key", consumerKey[:8]+"...",
		"wallet_address", req.WalletAddress,
		"amount_usd", req.AmountUSD,
		"amount_micro_usd", amountMicroUSD,
	)

	writeJSON(w, http.StatusOK, map[string]any{
		"status":           "deposited",
		"wallet_address":   req.WalletAddress,
		"amount_usd":       req.AmountUSD,
		"amount_micro_usd": amountMicroUSD,
		"balance_micro_usd": s.ledger.Balance(consumerKey),
	})
}

// handleBalance handles GET /v1/payments/balance.
// Returns the consumer's current balance in both micro-USD and USD.
func (s *Server) handleBalance(w http.ResponseWriter, r *http.Request) {
	consumerKey := consumerKeyFromContext(r.Context())
	balance := s.ledger.Balance(consumerKey)

	writeJSON(w, http.StatusOK, map[string]any{
		"balance_micro_usd": balance,
		"balance_usd":       fmt.Sprintf("%.6f", float64(balance)/1_000_000),
	})
}

// handleUsage handles GET /v1/payments/usage.
// Returns the consumer's inference usage history with per-request costs.
func (s *Server) handleUsage(w http.ResponseWriter, r *http.Request) {
	consumerKey := consumerKeyFromContext(r.Context())
	entries := s.ledger.Usage(consumerKey)

	writeJSON(w, http.StatusOK, map[string]any{
		"usage": entries,
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

// errorResponse builds a standard OpenAI-compatible error response body.
func errorResponse(errType, message string) map[string]any {
	return map[string]any{
		"error": map[string]any{
			"type":    errType,
			"message": message,
		},
	}
}
