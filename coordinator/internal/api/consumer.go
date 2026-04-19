package api

// Consumer-facing API handlers for the Darkbloom coordinator.
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
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/coordinator/internal/auth"
	"github.com/eigeninference/coordinator/internal/e2e"
	"github.com/eigeninference/coordinator/internal/payments"
	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
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

	// firstChunkTimeout is how long to wait for the first chunk from a provider
	// before considering the attempt failed and retrying.
	firstChunkTimeout = 10 * time.Second
)

// chatCompletionRequest is the incoming OpenAI-compatible request body.
// The consumer sends plain JSON — no encryption fields are needed because
// TLS to the Confidential VM is the trust boundary.
type chatCompletionRequest struct {
	Model       string                 `json:"model"`
	Messages    []protocol.ChatMessage `json:"messages"`
	Stream      bool                   `json:"stream"`
	MaxTokens   *int                   `json:"max_tokens,omitempty"`
	Temperature *float64               `json:"temperature,omitempty"`
}

// genericInferenceRequest captures any inference request body as raw JSON.
// Used for /v1/completions and /v1/messages endpoints where we pass the
// body through to the provider without parsing the endpoint-specific fields.
type genericInferenceRequest struct {
	Model  string `json:"model"`
	Stream bool   `json:"stream"`
	// RawBody is the complete request JSON, forwarded as-is to the provider.
	RawBody json.RawMessage `json:"-"`
}

func intFromRequestValue(v any) (int, bool) {
	switch x := v.(type) {
	case int:
		return x, true
	case int32:
		return int(x), true
	case int64:
		return int(x), true
	case float64:
		return int(x), true
	case json.Number:
		n, err := x.Int64()
		if err != nil {
			return 0, false
		}
		return int(n), true
	default:
		return 0, false
	}
}

func approximateTokenCount(v any) int {
	if v == nil {
		return 0
	}
	switch x := v.(type) {
	case string:
		if x == "" {
			return 0
		}
		tokens := len(x) / 4
		if tokens < 1 {
			tokens = 1
		}
		return tokens
	default:
		b, err := json.Marshal(v)
		if err != nil {
			return 0
		}
		tokens := len(b) / 4
		if tokens < 1 {
			tokens = 1
		}
		return tokens
	}
}

func estimatePromptTokens(parsed map[string]any) int {
	total := 0
	if v, ok := parsed["messages"]; ok {
		total += approximateTokenCount(v)
	}
	if v, ok := parsed["input"]; ok {
		total += approximateTokenCount(v)
	}
	if v, ok := parsed["prompt"]; ok {
		total += approximateTokenCount(v)
	}
	if total == 0 {
		total = approximateTokenCount(parsed)
	}
	return total
}

func estimateRequestedMaxTokens(parsed map[string]any) int {
	for _, key := range []string{"max_tokens", "max_completion_tokens", "max_output_tokens"} {
		if n, ok := intFromRequestValue(parsed[key]); ok && n > 0 {
			if copies, ok := intFromRequestValue(parsed["n"]); ok && copies > 1 {
				return n * copies
			}
			return n
		}
	}
	if copies, ok := intFromRequestValue(parsed["n"]); ok && copies > 1 {
		return 256 * copies
	}
	return 256
}

// defaultMaxOutputTokens is the ceiling injected into requests that don't set
// max_tokens. It bounds the worst-case cost of a single inference so the
// pre-flight balance reservation covers the entire generation; without this
// cap a consumer could stream output exceeding their reservation and the
// post-inference charge would fail silently (see GitHub issue #33). Consumers
// who need longer generations must set max_tokens explicitly and carry the
// balance to cover it.
const defaultMaxOutputTokens = 8192

// explicitMaxTokens returns the consumer-specified max output tokens from any
// of the recognized field names, or 0 if none were set.
func explicitMaxTokens(parsed map[string]any) int {
	for _, key := range []string{"max_tokens", "max_completion_tokens", "max_output_tokens"} {
		if n, ok := intFromRequestValue(parsed[key]); ok && n > 0 {
			return n
		}
	}
	return 0
}

// reservationCost is the pre-flight worst-case cost for a text inference
// request. It mirrors the platform-price branch of handleComplete's billing
// so the reservation covers any platform-level custom price for the model;
// without this, a platform override above the built-in default would leave
// the reservation short and the post-inference clamp would silently
// undercharge. Provider-specific custom prices are not known until dispatch
// commits to a provider, so a provider that sets a custom price above the
// platform rate accepts revenue capped at the reservation.
func (s *Server) reservationCost(model string, promptTokens, maxTokens int) int64 {
	customIn, customOut, hasCustom := s.store.GetModelPrice("platform", model)
	return payments.CalculateCostWithOverrides(model, promptTokens, maxTokens, customIn, customOut, hasCustom)
}

// ensureMaxTokensBound injects defaultMaxOutputTokens into parsed when the
// consumer didn't specify any max-tokens field, so the outgoing request to
// the provider is bounded by the amount we reserve upfront. The injected
// field name depends on the API flavor: Responses API uses max_output_tokens,
// everything else uses max_tokens. Returns true when an injection occurred,
// so the caller can re-marshal the outgoing body if needed.
func ensureMaxTokensBound(parsed map[string]any, isResponsesAPI bool) bool {
	if explicitMaxTokens(parsed) > 0 {
		return false
	}
	if isResponsesAPI {
		parsed["max_output_tokens"] = defaultMaxOutputTokens
	} else {
		parsed["max_tokens"] = defaultMaxOutputTokens
	}
	return true
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
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "model is required"))
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

	isResponsesAPI := input != nil && len(messages) == 0
	// If this is a Responses API request, tag it so the provider proxies
	// to /v1/responses instead of /v1/chat/completions.
	if isResponsesAPI {
		parsed["endpoint"] = "/v1/responses"
		rawBody, _ = json.Marshal(parsed)
	}

	// Smart prefill — opt-in attention-based prompt compression. When the
	// consumer sets `"smart_prefill": true` (or its equivalent extended
	// option), we route the prompt through a tiny-tier compressor first
	// and swap the result into the outgoing chat-completion body. The
	// big-tier model then runs prefill on a 2-5x shorter prompt at
	// >90% task quality. The compressor charge is added on top of the
	// inference charge — net economic impact is positive for the consumer
	// because compressor pricing is much cheaper than the prefill cycles
	// it saves (see docs/smart-prefill.md). Failures fall through silently
	// so smart_prefill is a best-effort optimization, never an availability
	// hazard. Disabled for Responses-API inputs in this revision (TODO).
	if smartPrefillRequested(parsed) && !isResponsesAPI {
		stats, applied := s.applySmartPrefill(r, parsed)
		if applied {
			rawBody, _ = json.Marshal(parsed)
			w.Header().Set("X-SmartPrefill-Original-Tokens", fmt.Sprintf("%d", stats.OriginalTokens))
			w.Header().Set("X-SmartPrefill-Compressed-Tokens", fmt.Sprintf("%d", stats.CompressedTokens))
			w.Header().Set("X-SmartPrefill-Compressor", stats.Compressor)
		}
	}

	// Bound the generation so the pre-flight reservation covers it. If the
	// consumer didn't set max_tokens, inject defaultMaxOutputTokens into the
	// outgoing body. Without this bound the provider could return more tokens
	// than we reserved for, and the silent post-inference charge failure would
	// hand the consumer free inference (GitHub issue #33).
	if ensureMaxTokensBound(parsed, isResponsesAPI) {
		rawBody, _ = json.Marshal(parsed)
	}

	stream, _ := parsed["stream"].(bool)
	estimatedPromptTokens := estimatePromptTokens(parsed)
	requestedMaxTokens := estimateRequestedMaxTokens(parsed)

	// Pre-flight balance reservation — atomically debit the worst-case cost
	// (prompt tokens already consumed + max_tokens we just bounded the
	// generation to) before routing to a provider. The post-inference charge
	// refunds any unused portion. Reserving only the minimum charge let
	// consumers receive streamed output far exceeding their actual balance.
	var reservedMicroUSD int64
	if s.billing != nil {
		consumerKey := consumerKeyFromContext(r.Context())
		reservedMicroUSD = s.reservationCost(model, estimatedPromptTokens, requestedMaxTokens)
		if err := s.ledger.Charge(consumerKey, reservedMicroUSD, "reserve:"+consumerKey); err != nil {
			writeJSON(w, http.StatusPaymentRequired, errorResponse("insufficient_funds",
				"your balance is too low for this request — add funds at /billing or lower max_tokens"))
			return
		}
	}

	// Refund reservation on early errors (before inference starts).
	refundReservation := func() {
		if reservedMicroUSD > 0 {
			consumerKey := consumerKeyFromContext(r.Context())
			_ = s.store.Credit(consumerKey, reservedMicroUSD, store.LedgerRefund, "reservation_refund")
		}
	}

	// Reject requests for models not in the catalog.
	if !s.registry.IsModelInCatalog(model) {
		refundReservation()
		writeJSON(w, http.StatusNotFound, errorResponse("model_not_found",
			fmt.Sprintf("model %q is not available — see /v1/models for supported models", model)))
		return
	}

	// Dispatch to a provider with automatic retry. If the first provider
	// fails (backend crashed, timeout, etc.), retry on the same or another
	// provider before returning an error to the consumer. We wait for the
	// first chunk before committing — no HTTP response is written until a
	// provider starts generating, so retries are invisible to the consumer.
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

	// Track providers that failed during retry so we don't dispatch to them again.
	excludeProviders := make(map[string]struct{})
	excludeList := func() []string {
		ids := make([]string, 0, len(excludeProviders))
		for id := range excludeProviders {
			ids = append(ids, id)
		}
		return ids
	}

	for attempt := 0; attempt < maxDispatchAttempts; attempt++ {
		requestID = uuid.New().String()
		pr = &registry.PendingRequest{
			RequestID:             requestID,
			Model:                 model,
			ConsumerKey:           consumerKey,
			EstimatedPromptTokens: estimatedPromptTokens,
			RequestedMaxTokens:    requestedMaxTokens,
			AcceptedCh:            make(chan struct{}, 1),
			ChunkCh:               make(chan string, chunkBufferSize),
			CompleteCh:            make(chan protocol.UsageInfo, 1),
			ErrorCh:               make(chan protocol.InferenceErrorMessage, 1),
		}

		provider = s.registry.ReserveProvider(model, pr, excludeList()...)
		if provider == nil {
			// On retry attempts, don't queue — if the only available
			// providers already failed, waiting 120s for one of them
			// to come back won't help. Break and return the last error.
			if attempt > 0 {
				break
			}
			// No idle provider — try queueing.
			queuedReq := &registry.QueuedRequest{
				RequestID:  requestID,
				Model:      model,
				Pending:    pr,
				ResponseCh: make(chan *registry.Provider, 1),
			}
			if err := s.registry.Queue().Enqueue(queuedReq); err != nil {
				refundReservation()
				writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_not_available", fmt.Sprintf("no hardware-trusted provider available for model %q and queue is full", model)))
				return
			}

			s.logger.Info("request queued, waiting for provider",
				"model", model,
				"attempt", attempt+1,
			)

			var err error
			provider, err = s.registry.Queue().WaitForProviderContext(r.Context(), queuedReq)
			if err != nil {
				if err == context.Canceled {
					refundReservation()
					return
				}
				refundReservation()
				writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_not_available", fmt.Sprintf("no hardware-trusted provider became available for model %q (queue timeout)", model)))
				return
			}
		}

		// E2E encryption — must be done per provider (different keys).
		if provider.PublicKey == "" {
			s.registry.SetProviderIdle(provider.ID)
			excludeProviders[provider.ID] = struct{}{}
			lastErr = "no provider with E2E encryption"
			continue
		}

		providerPubKey, err := e2e.ParsePublicKey(provider.PublicKey)
		if err != nil {
			s.registry.SetProviderIdle(provider.ID)
			excludeProviders[provider.ID] = struct{}{}
			lastErr = "provider public key invalid"
			continue
		}

		sessionKeys, err := e2e.GenerateSessionKeys()
		if err != nil {
			s.registry.SetProviderIdle(provider.ID)
			lastErr = "failed to generate session keys"
			continue
		}

		encrypted, err := e2e.Encrypt(rawBody, providerPubKey, sessionKeys)
		if err != nil {
			s.registry.SetProviderIdle(provider.ID)
			lastErr = "failed to encrypt request"
			continue
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
		pr.ReservedMicroUSD = reservedMicroUSD

		data, err := json.Marshal(wireMsg)
		if err != nil {
			provider.RemovePending(requestID)
			s.registry.SetProviderIdle(provider.ID)
			lastErr = "failed to marshal request"
			continue
		}
		if err := provider.Conn.Write(r.Context(), websocket.MessageText, data); err != nil {
			provider.RemovePending(requestID)
			s.registry.SetProviderIdle(provider.ID)
			excludeProviders[provider.ID] = struct{}{}
			s.logger.Error("failed to send inference request", "request_id", requestID, "error", err)
			lastErr = "failed to send request to provider"
			continue
		}

		s.logger.Info("inference request dispatched",
			"request_id", requestID,
			"model", model,
			"provider_id", provider.ID,
			"stream", stream,
			"attempt", attempt+1,
		)

		// Wait for an accepted signal, first chunk, or error before committing.
		// No HTTP response has been written yet, so retries are invisible.
		timer := time.NewTimer(firstChunkTimeout)
		accepted := false
		select {
		case <-pr.AcceptedCh:
			timer.Stop()
			accepted = true
		case chunk, ok := <-pr.ChunkCh:
			timer.Stop()
			if ok {
				firstChunk = chunk
				committed = true
			} else {
				// Channel closed — check if an error caused it.
				// handleInferenceError sends to ErrorCh then closes ChunkCh,
				// so both can be ready simultaneously.
				select {
				case errMsg := <-pr.ErrorCh:
					excludeProviders[provider.ID] = struct{}{}
					provider.RemovePending(requestID)
					s.registry.SetProviderIdle(provider.ID)
					lastErr = errMsg.Error
					lastErrCode = errMsg.StatusCode
					provider = nil
					pr = nil
					continue
				default:
					// No error — genuine empty response.
					committed = true
				}
			}
		case errMsg := <-pr.ErrorCh:
			timer.Stop()
			excludeProviders[provider.ID] = struct{}{}
			provider.RemovePending(requestID)
			s.registry.SetProviderIdle(provider.ID)
			lastErr = errMsg.Error
			lastErrCode = errMsg.StatusCode
			s.logger.Warn("provider failed, retrying",
				"request_id", requestID,
				"provider_id", provider.ID,
				"attempt", attempt+1,
				"error", errMsg.Error,
			)
			provider = nil
			pr = nil
			continue
		case <-timer.C:
			excludeProviders[provider.ID] = struct{}{}
			provider.RemovePending(requestID)
			s.registry.SetProviderIdle(provider.ID)
			cancelMsg := protocol.CancelMessage{Type: protocol.TypeCancel, RequestID: requestID}
			cancelData, _ := json.Marshal(cancelMsg)
			_ = provider.Conn.Write(context.Background(), websocket.MessageText, cancelData)
			lastErr = "timeout waiting for first response"
			lastErrCode = http.StatusGatewayTimeout
			s.logger.Warn("provider timeout, retrying",
				"request_id", requestID,
				"provider_id", provider.ID,
				"attempt", attempt+1,
			)
			provider = nil
			pr = nil
			continue
		case <-r.Context().Done():
			provider.RemovePending(requestID)
			s.registry.SetProviderIdle(provider.ID)
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
					committed = true
				} else {
					// Closed — check for error (same race as above).
					select {
					case errMsg := <-pr.ErrorCh:
						provider.RemovePending(requestID)
						s.registry.SetProviderIdle(provider.ID)
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
				cancelMsg := protocol.CancelMessage{Type: protocol.TypeCancel, RequestID: requestID}
				cancelData, _ := json.Marshal(cancelMsg)
				_ = provider.Conn.Write(context.Background(), websocket.MessageText, cancelData)
				refundReservation()
				writeJSON(w, http.StatusGatewayTimeout, errorResponse("timeout", "provider accepted but timed out"))
				return
			case <-r.Context().Done():
				provider.RemovePending(requestID)
				s.registry.SetProviderIdle(provider.ID)
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
			statusCode = http.StatusServiceUnavailable
		}
		writeJSON(w, statusCode, errorResponse("provider_error",
			fmt.Sprintf("inference failed after %d attempt(s): %s", maxDispatchAttempts, lastErr)))
		return
	}

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
		w.Header().Set("X-Provider-Public-Key", pubKey)
	}
	if attested {
		w.Header().Set("X-Provider-Attested", "true")
	} else {
		w.Header().Set("X-Provider-Attested", "false")
	}
	w.Header().Set("X-Provider-Trust-Level", string(trustLevel))
	w.Header().Set("X-Provider-ID", providerID)
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
		w.Header().Set("X-Provider-MDA-Verified", "true")
	}
	// SE public key for attestation receipt verification.
	// Consumers can use this to verify SE signatures on response hashes.
	if attestResult != nil && attestResult.PublicKey != "" {
		w.Header().Set("X-Attestation-SE-Public-Key", attestResult.PublicKey)
		w.Header().Set("X-Attestation-Device-Serial", attestResult.SerialNumber)
	}

	// When this function returns (consumer disconnect, timeout, or completion),
	// send a cancel to the provider so it stops generating tokens.
	defer func() {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)

		cancelMsg := protocol.CancelMessage{
			Type:      protocol.TypeCancel,
			RequestID: requestID,
		}
		cancelData, _ := json.Marshal(cancelMsg)
		if err := provider.Conn.Write(context.Background(), websocket.MessageText, cancelData); err != nil {
			s.logger.Debug("failed to send cancel (provider may have disconnected)", "request_id", requestID, "error", err)
		} else {
			s.logger.Info("sent cancel to provider", "request_id", requestID)
		}
	}()

	if stream {
		s.handleStreamingResponseWithFirstChunk(w, r, pr, firstChunk)
	} else {
		s.handleNonStreamingResponseWithFirstChunk(w, r, pr, firstChunk)
	}
}

// handleTranscriptions handles POST /v1/audio/transcriptions.
//
// This is the OpenAI-compatible audio transcription endpoint. It accepts
// multipart/form-data with an audio file and routes it to an STT-capable
// provider.
func (s *Server) handleTranscriptions(w http.ResponseWriter, r *http.Request) {
	// Parse multipart form (max 25MB audio)
	if err := r.ParseMultipartForm(25 << 20); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid multipart form: "+err.Error()))
		return
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "file field is required"))
		return
	}
	defer file.Close()

	model := r.FormValue("model")
	if model == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "model is required"))
		return
	}

	if !s.registry.IsModelInCatalog(model) {
		writeJSON(w, http.StatusNotFound, errorResponse("model_not_found",
			fmt.Sprintf("model %q is not available — see /v1/models for supported models", model)))
		return
	}

	language := r.FormValue("language")

	// Read the audio file into memory
	audioBytes, err := io.ReadAll(file)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "failed to read audio file"))
		return
	}

	// Determine audio format from filename extension
	ext := strings.TrimPrefix(filepath.Ext(header.Filename), ".")
	if ext == "" {
		ext = "wav"
	}

	requestID := uuid.New().String()
	consumerKey := consumerKeyFromContext(r.Context())
	pr := &registry.PendingRequest{
		RequestID:       requestID,
		Model:           model,
		ConsumerKey:     consumerKey,
		ChunkCh:         make(chan string, 1),
		CompleteCh:      make(chan protocol.UsageInfo, 1),
		ErrorCh:         make(chan protocol.InferenceErrorMessage, 1),
		TranscriptionCh: make(chan *protocol.TranscriptionCompleteMessage, 1),
	}

	// Find and reserve a provider that serves the requested STT model.
	provider := s.registry.ReserveProvider(model, pr)
	if provider == nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_not_available",
			fmt.Sprintf("no hardware-attested provider available for STT model %q", model)))
		return
	}

	transcriptionBody := protocol.TranscriptionRequestBody{
		Model:  model,
		Audio:  base64.StdEncoding.EncodeToString(audioBytes),
		Format: ext,
	}
	if language != "" {
		transcriptionBody.Language = &language
	}

	bodyJSON, _ := json.Marshal(transcriptionBody)

	// E2E encryption is mandatory for audio data. Providers without a public
	// key cannot receive transcription requests.
	if provider.PublicKey == "" {
		s.registry.SetProviderIdle(provider.ID)
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("encryption_required",
			"no provider with E2E encryption available for this model — audio data requires encryption"))
		return
	}

	providerPubKey, err := e2e.ParsePublicKey(provider.PublicKey)
	if err != nil {
		s.registry.SetProviderIdle(provider.ID)
		writeJSON(w, http.StatusInternalServerError, errorResponse("encryption_error",
			"provider public key invalid"))
		return
	}

	sessionKeys, err := e2e.GenerateSessionKeys()
	if err != nil {
		s.registry.SetProviderIdle(provider.ID)
		writeJSON(w, http.StatusInternalServerError, errorResponse("encryption_error",
			"failed to generate session keys"))
		return
	}

	encrypted, err := e2e.Encrypt(bodyJSON, providerPubKey, sessionKeys)
	if err != nil {
		s.registry.SetProviderIdle(provider.ID)
		writeJSON(w, http.StatusInternalServerError, errorResponse("encryption_error",
			"failed to encrypt transcription request"))
		return
	}

	wireMsg := map[string]any{
		"type":       protocol.TypeTranscriptionRequest,
		"request_id": requestID,
		"encrypted_body": map[string]string{
			"ephemeral_public_key": encrypted.EphemeralPublicKey,
			"ciphertext":           encrypted.Ciphertext,
		},
	}

	s.logger.Debug("transcription request encrypted for provider",
		"request_id", requestID,
		"provider_id", provider.ID,
	)
	if sessionKeys != nil {
		pr.SessionPrivKey = &sessionKeys.PrivateKey
	}

	// Send the request to the provider.
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
		s.logger.Error("failed to send transcription request", "request_id", requestID, "error", err)
		writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "failed to send request to provider"))
		return
	}

	s.logger.Info("transcription request dispatched",
		"request_id", requestID,
		"model", model,
		"provider_id", provider.ID,
		"audio_size", len(audioBytes),
		"format", ext,
	)

	// Cleanup on return.
	defer func() {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
	}()

	// Wait for the transcription result.
	ctx, cancel := context.WithTimeout(r.Context(), inferenceTimeout)
	defer cancel()

	select {
	case result := <-pr.TranscriptionCh:
		// Build OpenAI-compatible transcription response.
		resp := map[string]any{
			"text": result.Text,
		}
		if len(result.Segments) > 0 {
			resp["segments"] = result.Segments
		}
		if result.Language != "" {
			resp["language"] = result.Language
		}
		resp["duration"] = result.Usage.AudioSeconds
		writeJSON(w, http.StatusOK, resp)

	case errMsg := <-pr.ErrorCh:
		statusCode := errMsg.StatusCode
		if statusCode == 0 {
			statusCode = http.StatusBadGateway
		}
		writeJSON(w, statusCode, errorResponse("provider_error", errMsg.Error))

	case <-ctx.Done():
		writeJSON(w, http.StatusGatewayTimeout, errorResponse("timeout", "transcription request timed out"))
	}
}

// handleImageGenerations handles POST /v1/images/generations.
//
// This is the OpenAI-compatible image generation endpoint. It accepts a JSON
// body with model, prompt, size, etc. and routes it to an image-capable provider.
func (s *Server) handleImageGenerations(w http.ResponseWriter, r *http.Request) {
	var req protocol.ImageGenerationRequestBody
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}

	if req.Model == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "model is required"))
		return
	}
	if req.Prompt == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "prompt is required"))
		return
	}
	if req.N == 0 {
		req.N = 1
	}
	if req.N < 0 || req.N > 4 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "n must be between 1 and 4"))
		return
	}
	if !s.registry.IsModelInCatalog(req.Model) {
		writeJSON(w, http.StatusNotFound, errorResponse("model_not_found",
			fmt.Sprintf("model %q is not available — see /v1/models for supported models", req.Model)))
		return
	}
	if req.Steps != nil && *req.Steps <= 0 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "steps must be positive"))
		return
	}
	if req.Size == "" {
		req.Size = "1024x1024"
	}

	// Validate image dimensions — cap at 2048x2048 to keep responses under transport limits.
	sizeParts := strings.SplitN(req.Size, "x", 2)
	if len(sizeParts) != 2 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "size must be WxH (e.g. 1024x1024)"))
		return
	}
	imgW, _ := strconv.Atoi(sizeParts[0])
	imgH, _ := strconv.Atoi(sizeParts[1])
	if imgW <= 0 || imgH <= 0 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "size dimensions must be positive"))
		return
	}
	if imgW > 2048 || imgH > 2048 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "maximum image dimension is 2048x2048"))
		return
	}

	requestID := uuid.New().String()
	consumerKey := consumerKeyFromContext(r.Context())
	pr := &registry.PendingRequest{
		RequestID:         requestID,
		Model:             req.Model,
		ConsumerKey:       consumerKey,
		ChunkCh:           make(chan string, 1),
		CompleteCh:        make(chan protocol.UsageInfo, 1),
		ErrorCh:           make(chan protocol.InferenceErrorMessage, 1),
		ImageGenerationCh: make(chan *protocol.ImageGenerationCompleteMessage, 1),
	}

	// Find and reserve a hardware-attested provider that serves the requested image model.
	provider := s.registry.ReserveProvider(req.Model, pr)
	if provider == nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_not_available",
			fmt.Sprintf("no hardware-attested provider available for image model %q", req.Model)))
		return
	}

	bodyJSON, _ := json.Marshal(req)

	// E2E encryption — prompts are sensitive.
	if provider.PublicKey == "" {
		s.registry.SetProviderIdle(provider.ID)
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("encryption_required",
			"no provider with E2E encryption available for this model"))
		return
	}

	providerPubKey, err := e2e.ParsePublicKey(provider.PublicKey)
	if err != nil {
		s.registry.SetProviderIdle(provider.ID)
		writeJSON(w, http.StatusInternalServerError, errorResponse("encryption_error",
			"provider public key invalid"))
		return
	}

	sessionKeys, err := e2e.GenerateSessionKeys()
	if err != nil {
		s.registry.SetProviderIdle(provider.ID)
		writeJSON(w, http.StatusInternalServerError, errorResponse("encryption_error",
			"failed to generate session keys"))
		return
	}

	encrypted, err := e2e.Encrypt(bodyJSON, providerPubKey, sessionKeys)
	if err != nil {
		s.registry.SetProviderIdle(provider.ID)
		writeJSON(w, http.StatusInternalServerError, errorResponse("encryption_error",
			"failed to encrypt image generation request"))
		return
	}

	// Build the upload URL for the provider to POST generated images to.
	// Always use HTTPS — the coordinator runs behind nginx which terminates TLS,
	// so r.TLS is always nil, but the public URL must be HTTPS to avoid
	// HTTP→HTTPS 301 redirects that convert POST to GET (405 error).
	uploadURL := fmt.Sprintf("https://%s/v1/provider/image-upload?request_id=%s", r.Host, requestID)

	wireMsg := map[string]any{
		"type":       protocol.TypeImageGenerationRequest,
		"request_id": requestID,
		"upload_url": uploadURL,
		"encrypted_body": map[string]string{
			"ephemeral_public_key": encrypted.EphemeralPublicKey,
			"ciphertext":           encrypted.Ciphertext,
		},
	}
	if sessionKeys != nil {
		pr.SessionPrivKey = &sessionKeys.PrivateKey
	}

	// Send the request to the provider.
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
		s.logger.Error("failed to send image generation request", "request_id", requestID, "error", err)
		writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "failed to send request to provider"))
		return
	}

	s.logger.Info("image generation request dispatched",
		"request_id", requestID,
		"model", req.Model,
		"provider_id", provider.ID,
		"size", req.Size,
		"n", req.N,
	)

	// Cleanup on return.
	defer func() {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
	}()

	// Wait for the image generation result.
	ctx, cancel := context.WithTimeout(r.Context(), inferenceTimeout)
	defer cancel()

	select {
	case <-pr.ImageGenerationCh:
		// Retrieve images uploaded by the provider via HTTP.
		uploadedImages := s.getUploadedImages(requestID)
		imageData := make([]map[string]string, len(uploadedImages))
		for i, imgBytes := range uploadedImages {
			imageData[i] = map[string]string{
				"b64_json": base64.StdEncoding.EncodeToString(imgBytes),
			}
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"created": time.Now().Unix(),
			"data":    imageData,
		})

	case errMsg := <-pr.ErrorCh:
		statusCode := errMsg.StatusCode
		if statusCode == 0 {
			statusCode = http.StatusBadGateway
		}
		writeJSON(w, statusCode, errorResponse("provider_error", errMsg.Error))

	case <-ctx.Done():
		writeJSON(w, http.StatusGatewayTimeout, errorResponse("timeout", "image generation request timed out"))
	}
}

// handleStreamingResponse writes SSE events to the consumer as they arrive
// from the provider. Each chunk is forwarded in real time, providing
// token-by-token streaming to the consumer.
// handleStreamingResponse is kept for callers that don't have a first chunk.
func (s *Server) handleStreamingResponse(w http.ResponseWriter, r *http.Request, pr *registry.PendingRequest) {
	s.handleStreamingResponseWithFirstChunk(w, r, pr, "")
}

// handleStreamingResponseWithFirstChunk streams SSE chunks to the consumer.
// If firstChunk is non-empty, it is written before reading further chunks
// from the channel. This allows the dispatch loop to "peek" at the first
// chunk for retry decisions without losing it.
func (s *Server) handleStreamingResponseWithFirstChunk(w http.ResponseWriter, r *http.Request, pr *registry.PendingRequest, firstChunk string) {
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

	// Detect Responses API format to skip appending chat-completions-style
	// termination events (SE signature chunk + [DONE]).
	sawResponsesAPI := false

	// Write the first chunk that was already consumed during dispatch.
	if firstChunk != "" {
		if strings.Contains(firstChunk, `"response.created"`) || strings.Contains(firstChunk, `"response.output_text.delta"`) {
			sawResponsesAPI = true
		}
		if !sawResponsesAPI {
			firstChunk = normalizeSSEChunk(firstChunk)
		}
		fmt.Fprintf(w, "%s\n\n", firstChunk)
		flusher.Flush()
	}

	// Use a timer that resets on each chunk so long-running generations
	// (e.g. chain-of-thought models) don't hit a global timeout.
	timer := time.NewTimer(inferenceTimeout)
	defer timer.Stop()

	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if !ok {
				// Channel closed — inference complete.
				// For Responses API streams, the provider already sent
				// "response.completed" as the terminal event. Adding
				// extra chunks would break SDK parsers.
				if !sawResponsesAPI {
					// Chat completions format: append SE signature + [DONE].
					if pr.SESignature != "" {
						sigEvent, _ := json.Marshal(map[string]any{
							"choices":       []any{},
							"se_signature":  pr.SESignature,
							"response_hash": pr.ResponseHash,
						})
						fmt.Fprintf(w, "data: %s\n\n", sigEvent)
						flusher.Flush()
					}
					fmt.Fprint(w, "data: [DONE]\n\n")
					flusher.Flush()
				}
				return
			}
			if !sawResponsesAPI {
				if strings.Contains(chunk, `"response.created"`) || strings.Contains(chunk, `"response.output_text.delta"`) {
					sawResponsesAPI = true
				}
			}
			if !sawResponsesAPI {
				chunk = normalizeSSEChunk(chunk)
			}
			fmt.Fprintf(w, "%s\n\n", chunk)
			flusher.Flush()

			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			timer.Reset(inferenceTimeout)

		case errMsg := <-pr.ErrorCh:
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
			fmt.Fprintf(w, "data: {\"error\":{\"message\":\"request timed out\",\"type\":\"timeout\"}}\n\n")
			flusher.Flush()
			return

		case <-r.Context().Done():
			return
		}
	}
}

// handleNonStreamingResponse is kept for callers that don't have a first chunk.
func (s *Server) handleNonStreamingResponse(w http.ResponseWriter, r *http.Request, pr *registry.PendingRequest) {
	s.handleNonStreamingResponseWithFirstChunk(w, r, pr, "")
}

// handleNonStreamingResponseWithFirstChunk collects all chunks from the
// provider and assembles them into a single OpenAI-compatible JSON response.
// If firstChunk is non-empty, it is prepended to the collected chunks.
func (s *Server) handleNonStreamingResponseWithFirstChunk(w http.ResponseWriter, r *http.Request, pr *registry.PendingRequest, firstChunk string) {
	ctx, cancel := context.WithTimeout(r.Context(), inferenceTimeout)
	defer cancel()

	var chunks []string
	if firstChunk != "" {
		chunks = append(chunks, firstChunk)
	}

	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if !ok {
				// The provider forwards the raw backend response as a single
				// chunk. Detect complete responses (object=chat.completion
				// or object=response) and pass through directly — this is
				// format-agnostic and works for chat completions, Responses
				// API, or any future endpoint without parsing.
				if len(chunks) == 1 {
					raw := strings.TrimPrefix(chunks[0], "data: ")
					var obj map[string]any
					if json.Unmarshal([]byte(raw), &obj) == nil {
						objType, _ := obj["object"].(string)
						// Complete responses have object=chat.completion or
						// object=response. Delta chunks have object=chat.completion.chunk.
						if objType == "chat.completion" || objType == "response" {
							select {
							case <-pr.CompleteCh:
							case <-ctx.Done():
							}
							if pr.SESignature != "" {
								obj["se_signature"] = pr.SESignature
								obj["response_hash"] = pr.ResponseHash
							}
							writeJSON(w, http.StatusOK, obj)
							return
						}
					}
				}

				// Fallback: SSE delta chunks — reconstruct into response.
				msg := extractMessage(chunks)
				select {
				case usage := <-pr.CompleteCh:
					resp := buildNonStreamingResponse(pr.RequestID, pr.Model, msg, usage, pr.SESignature, pr.ResponseHash)
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

// normalizeSSEChunk fixes fields in SSE chunks to match the OpenAI spec.
// Some backends (e.g. vllm-mlx) emit "content":null instead of "content":"",
// and include "usage":null which strict parsers (ForgeCode, Codex) reject
// because they expect usage to be either absent or a full object.
func normalizeSSEChunk(chunk string) string {
	line := strings.TrimPrefix(chunk, "data: ")
	// Only trigger the expensive JSON parse for fields we actually fix.
	// "finish_reason":null appears on every chunk but we don't touch it,
	// so checking for generic ":null" causes unnecessary JSON round-trips.
	needsNullFix := strings.Contains(line, `"content":null`) ||
		strings.Contains(line, `"tool_calls":null`) ||
		strings.Contains(line, `"usage":null`) ||
		strings.Contains(line, `"reasoning":null`) ||
		strings.Contains(line, `"reasoning_content":null`) ||
		strings.Contains(line, `"refusal":null`) ||
		strings.Contains(line, `"system_fingerprint":null`)
	needsReasoningDedup := strings.Contains(line, `"reasoning_content"`)
	if !needsNullFix && !needsReasoningDedup {
		return chunk
	}

	var raw map[string]json.RawMessage
	if err := json.Unmarshal([]byte(line), &raw); err != nil {
		return chunk
	}

	changed := false

	// Remove top-level null fields (usage, system_fingerprint, etc.)
	// ForgeCode expects usage to be absent or a full object, not null.
	for _, key := range []string{"usage", "system_fingerprint"} {
		if v, ok := raw[key]; ok && string(v) == "null" {
			delete(raw, key)
			changed = true
		}
	}

	// Fix null fields inside choices[].delta
	if choicesRaw, ok := raw["choices"]; ok {
		var choices []map[string]json.RawMessage
		if err := json.Unmarshal(choicesRaw, &choices); err == nil {
			for i, choice := range choices {
				if deltaRaw, ok := choice["delta"]; ok {
					var delta map[string]json.RawMessage
					if err := json.Unmarshal(deltaRaw, &delta); err == nil {
						for _, field := range []string{"content", "reasoning_content", "reasoning", "refusal"} {
							if v, ok := delta[field]; ok && string(v) == "null" {
								delta[field] = json.RawMessage(`""`)
								changed = true
							}
						}
						if v, ok := delta["tool_calls"]; ok && string(v) == "null" {
							delta["tool_calls"] = json.RawMessage(`[]`)
							changed = true
						}
						// ForgeCode uses #[serde(alias = "reasoning_content")] on
						// the "reasoning" field. If both keys are present, serde
						// fails with a duplicate-field error. Keep only "reasoning".
						if _, hasR := delta["reasoning"]; hasR {
							if _, hasRC := delta["reasoning_content"]; hasRC {
								delete(delta, "reasoning_content")
								changed = true
							}
						} else if rc, hasRC := delta["reasoning_content"]; hasRC {
							// Only reasoning_content exists — rename to reasoning.
							delta["reasoning"] = rc
							delete(delta, "reasoning_content")
							changed = true
						}
						if changed {
							choices[i]["delta"], _ = json.Marshal(delta)
						}
					}
				}
			}
			if changed {
				raw["choices"], _ = json.Marshal(choices)
			}
		}
	}

	if !changed {
		return chunk
	}

	out, err := json.Marshal(raw)
	if err != nil {
		return chunk
	}
	return "data: " + string(out)
}

// extractedMessage holds the reconstructed assistant message from SSE chunks,
// including text content, reasoning, and any tool calls.
type extractedMessage struct {
	Content   string           `json:"content"`
	Reasoning string           `json:"reasoning,omitempty"`
	ToolCalls []map[string]any `json:"tool_calls,omitempty"`
}

// extractMessage parses SSE data lines and reconstructs the full assistant
// message from streaming chunks, including content, reasoning, and tool_calls.
func extractMessage(chunks []string) extractedMessage {
	var contentBuilder strings.Builder
	var reasoningBuilder strings.Builder
	// Tool calls are indexed — accumulate argument fragments by index.
	toolCallMap := map[int]map[string]any{}

	for _, chunk := range chunks {
		line := strings.TrimPrefix(chunk, "data: ")
		line = strings.TrimSpace(line)
		if line == "" || line == "[DONE]" {
			continue
		}

		var parsed map[string]json.RawMessage
		if err := json.Unmarshal([]byte(line), &parsed); err != nil {
			continue
		}

		choicesRaw, ok := parsed["choices"]
		if !ok {
			continue
		}
		var choices []struct {
			Delta struct {
				Content   string `json:"content"`
				Reasoning string `json:"reasoning"`
				ToolCalls []struct {
					Index    int    `json:"index"`
					ID       string `json:"id,omitempty"`
					Type     string `json:"type,omitempty"`
					Function struct {
						Name      string `json:"name,omitempty"`
						Arguments string `json:"arguments,omitempty"`
					} `json:"function,omitempty"`
				} `json:"tool_calls,omitempty"`
			} `json:"delta"`
			FinishReason *string `json:"finish_reason"`
		}
		if err := json.Unmarshal(choicesRaw, &choices); err != nil {
			continue
		}

		for _, c := range choices {
			contentBuilder.WriteString(c.Delta.Content)
			reasoningBuilder.WriteString(c.Delta.Reasoning)
			for _, tc := range c.Delta.ToolCalls {
				existing, ok := toolCallMap[tc.Index]
				if !ok {
					existing = map[string]any{
						"index": tc.Index,
						"function": map[string]any{
							"arguments": "",
						},
					}
					toolCallMap[tc.Index] = existing
				}
				if tc.ID != "" {
					existing["id"] = tc.ID
				}
				if tc.Type != "" {
					existing["type"] = tc.Type
				}
				fn := existing["function"].(map[string]any)
				if tc.Function.Name != "" {
					fn["name"] = tc.Function.Name
				}
				fn["arguments"] = fn["arguments"].(string) + tc.Function.Arguments
			}
		}
	}

	msg := extractedMessage{Content: contentBuilder.String(), Reasoning: reasoningBuilder.String()}
	if len(toolCallMap) > 0 {
		msg.ToolCalls = make([]map[string]any, 0, len(toolCallMap))
		for i := 0; i < len(toolCallMap); i++ {
			if tc, ok := toolCallMap[i]; ok {
				delete(tc, "index")
				msg.ToolCalls = append(msg.ToolCalls, tc)
			}
		}
	}
	return msg
}

// buildNonStreamingResponse constructs a complete OpenAI-compatible chat
// completion response from the aggregated message and usage info.
func buildNonStreamingResponse(requestID, model string, msg extractedMessage, usage protocol.UsageInfo, seSignature, responseHash string) map[string]any {
	message := map[string]any{
		"role":    "assistant",
		"content": msg.Content,
	}
	if msg.Reasoning != "" {
		message["reasoning"] = msg.Reasoning
	}

	finishReason := "stop"
	if len(msg.ToolCalls) > 0 {
		message["tool_calls"] = msg.ToolCalls
		finishReason = "tool_calls"
	}

	resp := map[string]any{
		"id":      "chatcmpl-" + requestID,
		"object":  "chat.completion",
		"created": time.Now().Unix(),
		"model":   model,
		"choices": []map[string]any{
			{
				"index":         0,
				"message":       message,
				"finish_reason": finishReason,
			},
		},
		"usage": map[string]any{
			"prompt_tokens":     usage.PromptTokens,
			"completion_tokens": usage.CompletionTokens,
			"total_tokens":      usage.PromptTokens + usage.CompletionTokens,
		},
	}

	// Include SE signature if the provider signed the response
	if seSignature != "" {
		resp["se_signature"] = seSignature
		resp["response_hash"] = responseHash
	}

	return resp
}

// handleListModels handles GET /v1/models.
//
// Returns a deduplicated list of models across all connected providers,
// including attestation metadata (trust level, Secure Enclave status,
// provider count) for each model.
func (s *Server) handleListModels(w http.ResponseWriter, r *http.Request) {
	models := s.registry.ListModels()

	// Filter to only show models from the catalog (active supported models).
	catalogModels := s.store.ListSupportedModels()
	catalogByID := make(map[string]store.SupportedModel, len(catalogModels))
	for _, cm := range catalogModels {
		if cm.Active {
			catalogByID[cm.ID] = cm
		}
	}

	data := make([]map[string]any, 0, len(models))
	for _, m := range models {
		cm, inCatalog := catalogByID[m.ID]
		if len(catalogByID) > 0 && !inCatalog {
			continue
		}
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
		if inCatalog && cm.DisplayName != "" {
			metadata["display_name"] = cm.DisplayName
		}
		data = append(data, map[string]any{
			"id":       m.ID,
			"object":   "model",
			"created":  0,
			"owned_by": "eigeninference",
			"metadata": metadata,
		})
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"object": "list",
		"data":   data,
	})
}

// handleCreateKey handles POST /v1/auth/keys — creates a new consumer API key.
// Requires Privy authentication. The key is linked to the user's account so
// requests made with the key are billed to the same account.
func (s *Server) handleCreateKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		writeJSON(w, http.StatusUnauthorized, errorResponse("auth_error",
			"API key creation requires a Privy account — authenticate with a Privy access token"))
		return
	}

	key, err := s.store.CreateKeyForAccount(user.AccountID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("server_error", "failed to create key"))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"api_key":    key,
		"account_id": user.AccountID,
	})
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

// handleVersion returns the latest provider CLI version and download URL.
// Providers call GET /api/version to check if they need to update.
// If a release is registered in the store, uses that. Otherwise falls back
// to the hardcoded LatestProviderVersion.
func (s *Server) handleVersion(w http.ResponseWriter, r *http.Request) {
	// Try release table first.
	if release := s.store.GetLatestRelease("macos-arm64"); release != nil {
		writeJSON(w, http.StatusOK, map[string]any{
			"version":      release.Version,
			"download_url": release.URL,
			"bundle_hash":  release.BundleHash,
			"changelog":    release.Changelog,
		})
		return
	}

	// Fallback to hardcoded version + coordinator download.
	scheme := "https"
	if r.TLS == nil && !strings.Contains(r.Host, "darkbloom.dev") {
		scheme = "http"
	}
	downloadURL := fmt.Sprintf("%s://%s/dl/eigeninference-bundle-macos-arm64.tar.gz", scheme, r.Host)

	writeJSON(w, http.StatusOK, map[string]any{
		"version":      LatestProviderVersion,
		"download_url": downloadURL,
	})
}

// --- payment handlers ---

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
			entries = append(entries, payments.UsageEntry{
				JobID:            jobID,
				Model:            u.Model,
				PromptTokens:     u.PromptTokens,
				CompletionTokens: u.CompletionTokens,
				CostMicroUSD:     u.CostMicroUSD,
				Timestamp:        u.CreatedAt,
			})
		}
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"usage": entries,
	})
}

// handleProviderEarnings handles GET /v1/provider/earnings?wallet=0x...
//
// Returns the provider's balance and payout history by wallet address.
// No API key auth required — providers identify by wallet address.
// The wallet address is the same one sent during WebSocket registration.
func (s *Server) handleProviderEarnings(w http.ResponseWriter, r *http.Request) {
	wallet := r.URL.Query().Get("wallet")
	if wallet == "" {
		wallet = r.Header.Get("X-Provider-Wallet")
	}
	if wallet == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "wallet address required (query param ?wallet=0x... or X-Provider-Wallet header)"))
		return
	}

	// Look up balance by wallet address (same account ID used in CreditProvider)
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

	writeJSON(w, http.StatusOK, map[string]any{
		"wallet_address":         wallet,
		"balance_micro_usd":      balance,
		"balance_usd":            fmt.Sprintf("%.6f", float64(balance)/1_000_000),
		"total_earned_micro_usd": totalEarned,
		"total_earned_usd":       fmt.Sprintf("%.6f", float64(totalEarned)/1_000_000),
		"total_jobs":             totalJobs,
		"payouts":                walletPayouts,
		"ledger":                 history,
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
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "model is required"))
		return
	}
	if !s.registry.IsModelInCatalog(model) {
		writeJSON(w, http.StatusNotFound, errorResponse("model_not_found",
			fmt.Sprintf("model %q is not available — see /v1/models for supported models", model)))
		return
	}

	// Completions and Anthropic messages both use the max_tokens field (never
	// max_output_tokens, which is Responses API only). Inject a default if
	// unset so the pre-flight reservation bounds the generation.
	ensureMaxTokensBound(parsed, false)

	stream, _ := parsed["stream"].(bool)
	estimatedPromptTokens := estimatePromptTokens(parsed)
	requestedMaxTokens := estimateRequestedMaxTokens(parsed)

	// Inject the endpoint so the provider knows which local path to forward to.
	parsed["endpoint"] = endpoint

	// Pre-flight balance reservation — same worst-case-cost reservation as
	// handleChatCompletions. Before this fix the completions and Anthropic
	// paths routed without ANY reservation; the silent post-inference charge
	// meant a consumer could receive full responses with a zero balance.
	consumerKey := consumerKeyFromContext(r.Context())
	var reservedMicroUSD int64
	if s.billing != nil {
		reservedMicroUSD = s.reservationCost(model, estimatedPromptTokens, requestedMaxTokens)
		if err := s.ledger.Charge(consumerKey, reservedMicroUSD, "reserve:"+consumerKey); err != nil {
			writeJSON(w, http.StatusPaymentRequired, errorResponse("insufficient_funds",
				"your balance is too low for this request — add funds at /billing or lower max_tokens"))
			return
		}
	}
	// Refund the reservation on any early failure before dispatch.
	refundReservation := func() {
		if reservedMicroUSD > 0 {
			_ = s.store.Credit(consumerKey, reservedMicroUSD, store.LedgerRefund, "reservation_refund")
		}
	}

	requestID := uuid.New().String()
	pr := &registry.PendingRequest{
		RequestID:             requestID,
		Model:                 model,
		ConsumerKey:           consumerKey,
		EstimatedPromptTokens: estimatedPromptTokens,
		RequestedMaxTokens:    requestedMaxTokens,
		ReservedMicroUSD:      reservedMicroUSD,
		ChunkCh:               make(chan string, chunkBufferSize),
		CompleteCh:            make(chan protocol.UsageInfo, 1),
		ErrorCh:               make(chan protocol.InferenceErrorMessage, 1),
	}

	provider := s.registry.ReserveProvider(model, pr)
	if provider == nil {
		queuedReq := &registry.QueuedRequest{
			RequestID:  requestID,
			Model:      model,
			Pending:    pr,
			ResponseCh: make(chan *registry.Provider, 1),
		}
		if err := s.registry.Queue().Enqueue(queuedReq); err != nil {
			refundReservation()
			writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_not_available",
				fmt.Sprintf("no provider available for model %q", model)))
			return
		}
		provider, err = s.registry.Queue().WaitForProviderContext(r.Context(), queuedReq)
		if err != nil {
			if err == context.Canceled {
				refundReservation()
				return
			}
			refundReservation()
			writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_not_available",
				fmt.Sprintf("no provider became available for model %q", model)))
			return
		}
	}

	inferenceBody, _ := json.Marshal(parsed)

	if provider.PublicKey == "" {
		s.registry.SetProviderIdle(provider.ID)
		refundReservation()
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("encryption_required",
			"no provider with E2E encryption available"))
		return
	}

	providerPubKey, err := e2e.ParsePublicKey(provider.PublicKey)
	if err != nil {
		s.registry.SetProviderIdle(provider.ID)
		refundReservation()
		writeJSON(w, http.StatusInternalServerError, errorResponse("encryption_error", "provider public key invalid"))
		return
	}

	sessionKeys, err := e2e.GenerateSessionKeys()
	if err != nil {
		s.registry.SetProviderIdle(provider.ID)
		refundReservation()
		writeJSON(w, http.StatusInternalServerError, errorResponse("encryption_error", "failed to generate session keys"))
		return
	}

	encrypted, err := e2e.Encrypt(inferenceBody, providerPubKey, sessionKeys)
	if err != nil {
		s.registry.SetProviderIdle(provider.ID)
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
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		refundReservation()
		writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "failed to send request to provider"))
		return
	}

	s.logger.Info("inference request dispatched",
		"request_id", requestID,
		"model", model,
		"provider_id", provider.ID,
		"endpoint", endpoint,
		"stream", stream,
	)

	if stream {
		s.handleStreamingResponse(w, r, pr)
	} else {
		s.handleNonStreamingResponse(w, r, pr)
	}
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
