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
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/dginf/coordinator/internal/auth"
	"github.com/dginf/coordinator/internal/e2e"
	"github.com/dginf/coordinator/internal/payments"
	"github.com/dginf/coordinator/internal/protocol"
	"github.com/dginf/coordinator/internal/registry"
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

	// Consumer-selectable trust level. Consumers can request a minimum trust
	// tier (e.g. "hardware") to filter providers. If not specified, uses the
	// registry's default (hardware).
	var requestedTrust registry.TrustLevel
	if trustParam := r.URL.Query().Get("trust_level"); trustParam != "" {
		requestedTrust = registry.TrustLevel(trustParam)
		if trustRank := registry.TrustRank(requestedTrust); trustRank < 0 {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
				fmt.Sprintf("invalid trust_level %q — valid values: none, self_signed, hardware", trustParam)))
			return
		}
	}

	// Find a provider that serves the requested model.
	provider := s.registry.FindProviderWithTrust(req.Model, requestedTrust)
	if provider == nil {
		trustDesc := "hardware-trusted"
		if requestedTrust != "" {
			trustDesc = string(requestedTrust)
		}
		// No idle provider at requested trust — try queueing.
		queuedReq := &registry.QueuedRequest{
			RequestID:  uuid.New().String(),
			Model:      req.Model,
			ResponseCh: make(chan *registry.Provider, 1),
		}
		if err := s.registry.Queue().Enqueue(queuedReq); err != nil {
			writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_not_available", fmt.Sprintf("no %s provider available for model %q and queue is full", trustDesc, req.Model)))
			return
		}

		s.logger.Info("request queued, waiting for provider",
			"model", req.Model,
			"trust_level", trustDesc,
			"queue_request_id", queuedReq.RequestID,
		)

		var err error
		provider, err = s.registry.Queue().WaitForProvider(queuedReq)
		if err != nil {
			writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_not_available", fmt.Sprintf("no %s provider became available for model %q (queue timeout)", trustDesc, req.Model)))
			return
		}
	}

	// Build the inference request to forward to the provider.
	// Prompt content is never logged.
	requestID := uuid.New().String()

	plainBody := protocol.InferenceRequestBody{
		Model:       req.Model,
		Messages:    req.Messages,
		Stream:      req.Stream,
		MaxTokens:   req.MaxTokens,
		Temperature: req.Temperature,
	}
	inferenceBody, _ := json.Marshal(plainBody)

	// E2E encryption is mandatory. Providers without a public key cannot
	// receive inference requests — consumer prompts must never travel in plaintext.
	if provider.PublicKey == "" {
		s.registry.SetProviderIdle(provider.ID)
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("encryption_required",
			"no provider with E2E encryption available for this model — prompt data requires encryption"))
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

	encrypted, err := e2e.Encrypt(inferenceBody, providerPubKey, sessionKeys)
	if err != nil {
		s.registry.SetProviderIdle(provider.ID)
		writeJSON(w, http.StatusInternalServerError, errorResponse("encryption_error",
			"failed to encrypt request"))
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

	s.logger.Debug("request encrypted for provider",
		"request_id", requestID,
		"provider_id", provider.ID,
	)

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
	pr.SessionPrivKey = &sessionKeys.PrivateKey
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
	w.Header().Set("X-Provider-ID", provider.ID)
	w.Header().Set("X-Provider-Chip", provider.Hardware.ChipName)
	w.Header().Set("X-Provider-Model", provider.Hardware.MachineModel)
	if provider.AttestationResult != nil {
		w.Header().Set("X-Provider-Serial", provider.AttestationResult.SerialNumber)
		if provider.AttestationResult.SecureEnclaveAvailable {
			w.Header().Set("X-Provider-Secure-Enclave", "true")
		} else {
			w.Header().Set("X-Provider-Secure-Enclave", "false")
		}
	}
	if provider.MDAVerified {
		w.Header().Set("X-Provider-MDA-Verified", "true")
	}

	// When this function returns (consumer disconnect, timeout, or completion),
	// send a cancel to the provider so it stops generating tokens.
	defer func() {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)

		// Send cancel to provider — if the request already completed this is a no-op
		// on the provider side (unknown request_id).
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

	if req.Stream {
		s.handleStreamingResponse(w, r, pr)
	} else {
		s.handleNonStreamingResponse(w, r, pr)
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

	// Find a provider that serves the requested STT model.
	provider := s.registry.FindProviderWithTrust(model, "")
	if provider == nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_not_available",
			fmt.Sprintf("no provider available for STT model %q", model)))
		return
	}

	// Build the transcription request.
	requestID := uuid.New().String()
	consumerKey := consumerKeyFromContext(r.Context())

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

	// Create pending request with transcription channel.
	pr := &registry.PendingRequest{
		RequestID:       requestID,
		ProviderID:      provider.ID,
		Model:           model,
		ConsumerKey:     consumerKey,
		ChunkCh:         make(chan string, 1),
		CompleteCh:      make(chan protocol.UsageInfo, 1),
		ErrorCh:         make(chan protocol.InferenceErrorMessage, 1),
		TranscriptionCh: make(chan *protocol.TranscriptionCompleteMessage, 1),
	}
	if sessionKeys != nil {
		pr.SessionPrivKey = &sessionKeys.PrivateKey
	}
	provider.AddPending(pr)

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
	if req.Steps != nil && *req.Steps <= 0 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "steps must be positive"))
		return
	}
	if req.Size == "" {
		req.Size = "1024x1024"
	}

	// Find a provider that serves the requested image model.
	requestedTrust := registry.TrustLevel(r.URL.Query().Get("trust_level"))
	provider := s.registry.FindProviderWithTrust(req.Model, requestedTrust)
	if provider == nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_not_available",
			fmt.Sprintf("no provider available for image model %q", req.Model)))
		return
	}

	requestID := uuid.New().String()
	consumerKey := consumerKeyFromContext(r.Context())

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

	wireMsg := map[string]any{
		"type":       protocol.TypeImageGenerationRequest,
		"request_id": requestID,
		"encrypted_body": map[string]string{
			"ephemeral_public_key": encrypted.EphemeralPublicKey,
			"ciphertext":           encrypted.Ciphertext,
		},
	}

	// Create pending request with image generation channel.
	pr := &registry.PendingRequest{
		RequestID:         requestID,
		ProviderID:        provider.ID,
		Model:             req.Model,
		ConsumerKey:       consumerKey,
		ChunkCh:           make(chan string, 1),
		CompleteCh:        make(chan protocol.UsageInfo, 1),
		ErrorCh:           make(chan protocol.InferenceErrorMessage, 1),
		ImageGenerationCh: make(chan *protocol.ImageGenerationCompleteMessage, 1),
	}
	if sessionKeys != nil {
		pr.SessionPrivKey = &sessionKeys.PrivateKey
	}
	provider.AddPending(pr)

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
	case result := <-pr.ImageGenerationCh:
		// Build OpenAI-compatible image generation response.
		imageData := make([]map[string]string, len(result.Images))
		for i, img := range result.Images {
			imageData[i] = map[string]string{"b64_json": img.B64JSON}
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

	// Use a timer that resets on each chunk so long-running generations
	// (e.g. chain-of-thought models) don't hit a global timeout.
	timer := time.NewTimer(inferenceTimeout)
	defer timer.Stop()

	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if !ok {
				// Channel closed — inference complete.
				// Include SE signature as final event before [DONE]
				if pr.SESignature != "" {
					sigEvent, _ := json.Marshal(map[string]any{
						"se_signature":  pr.SESignature,
						"response_hash": pr.ResponseHash,
					})
					fmt.Fprintf(w, "data: %s\n\n", sigEvent)
					flusher.Flush()
				}
				fmt.Fprint(w, "data: [DONE]\n\n")
				flusher.Flush()
				return
			}
			// The chunk data from the provider includes the "data: ..." SSE prefix.
			// Append \n\n to form a valid SSE event boundary.
			fmt.Fprintf(w, "%s\n\n", chunk)
			flusher.Flush()

			// Reset the timer — as long as chunks keep flowing, don't timeout.
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			timer.Reset(inferenceTimeout)

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

		case <-timer.C:
			fmt.Fprintf(w, "data: {\"error\":{\"message\":\"request timed out\",\"type\":\"timeout\"}}\n\n")
			flusher.Flush()
			return

		case <-r.Context().Done():
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
					resp := buildNonStreamingResponse(pr.RequestID, pr.Model, content, usage, pr.SESignature, pr.ResponseHash)
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
func buildNonStreamingResponse(requestID, model, content string, usage protocol.UsageInfo, seSignature, responseHash string) map[string]any {
	resp := map[string]any{
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
func (s *Server) handleVersion(w http.ResponseWriter, r *http.Request) {
	scheme := "https"
	if r.TLS == nil && !strings.Contains(r.Host, "openinnovation.dev") {
		scheme = "http"
	}
	downloadURL := fmt.Sprintf("%s://%s/dl/dginf-bundle-macos-arm64.tar.gz", scheme, r.Host)

	writeJSON(w, http.StatusOK, map[string]any{
		"version":      LatestProviderVersion,
		"download_url": downloadURL,
	})
}

// --- payment handlers ---

// depositRequest is the JSON body for POST /v1/payments/deposit.
// If TxHash is provided, the deposit is verified on-chain via the settlement
// service. Otherwise, the trust-based MVP flow is used.
type depositRequest struct {
	WalletAddress string `json:"wallet_address"`
	AmountUSD     string `json:"amount_usd"`
	TxHash        string `json:"tx_hash,omitempty"`
}

// settlementVerifyResponse is the JSON response from the settlement service's
// POST /v1/settlement/verify-deposit endpoint.
type settlementVerifyResponse struct {
	Verified       bool   `json:"verified"`
	TxHash         string `json:"txHash"`
	From           string `json:"from"`
	Amount         string `json:"amount"`
	AmountUSD      string `json:"amountUSD"`
	AmountMicroUSD int64  `json:"amountMicroUSD"`
	BlockNumber    string `json:"blockNumber"`
	Error          string `json:"error,omitempty"`
}

// txHashMu protects processedTxHashes for concurrent access.
var txHashMu sync.Mutex

// handleDeposit handles POST /v1/payments/deposit.
//
// Two modes:
//   - If tx_hash is provided: verify the on-chain pathUSD transfer via the
//     settlement service, then credit the verified amount. The tx_hash is
//     recorded to prevent double-crediting.
//   - If tx_hash is absent: use the trust-based MVP flow (direct ledger credit).
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

	consumerKey := consumerKeyFromContext(r.Context())

	// On-chain verified deposit flow
	if req.TxHash != "" {
		s.handleVerifiedDeposit(w, consumerKey, req)
		return
	}

	// Trust-based deposit flow (MVP)
	if req.AmountUSD == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "amount_usd is required"))
		return
	}

	amountFloat, err := strconv.ParseFloat(req.AmountUSD, 64)
	if err != nil || amountFloat <= 0 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "amount_usd must be a positive number"))
		return
	}

	amountMicroUSD := int64(amountFloat * 1_000_000)

	if err := s.ledger.Deposit(consumerKey, amountMicroUSD); err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to credit balance"))
		return
	}

	s.logger.Info("deposit credited (trust-based)",
		"consumer_key", consumerKey[:8]+"...",
		"wallet_address", req.WalletAddress,
		"amount_usd", req.AmountUSD,
		"amount_micro_usd", amountMicroUSD,
	)

	writeJSON(w, http.StatusOK, map[string]any{
		"status":            "deposited",
		"wallet_address":    req.WalletAddress,
		"amount_usd":        req.AmountUSD,
		"amount_micro_usd":  amountMicroUSD,
		"balance_micro_usd": s.ledger.Balance(consumerKey),
	})
}

// handleVerifiedDeposit verifies a deposit on-chain via the settlement service.
func (s *Server) handleVerifiedDeposit(w http.ResponseWriter, consumerKey string, req depositRequest) {
	// Check for double-crediting
	txHashMu.Lock()
	if s.processedTxHashes[req.TxHash] {
		txHashMu.Unlock()
		writeJSON(w, http.StatusConflict, errorResponse("duplicate_deposit", "tx_hash has already been processed"))
		return
	}
	txHashMu.Unlock()

	// Call settlement service to verify the on-chain transfer
	verifyBody, _ := json.Marshal(map[string]string{"tx_hash": req.TxHash})
	resp, err := http.Post(
		s.settlementURL+"/v1/settlement/verify-deposit",
		"application/json",
		bytes.NewReader(verifyBody),
	)
	if err != nil {
		s.logger.Error("settlement service unreachable", "error", err)
		writeJSON(w, http.StatusBadGateway, errorResponse("settlement_error", "settlement service unreachable"))
		return
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to read settlement response"))
		return
	}

	var verifyResp settlementVerifyResponse
	if err := json.Unmarshal(body, &verifyResp); err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to parse settlement response"))
		return
	}

	if !verifyResp.Verified {
		errMsg := "deposit verification failed"
		if verifyResp.Error != "" {
			errMsg = verifyResp.Error
		}
		writeJSON(w, http.StatusBadRequest, errorResponse("verification_failed", errMsg))
		return
	}

	// Mark tx_hash as processed to prevent double-crediting
	txHashMu.Lock()
	// Double-check after acquiring the lock
	if s.processedTxHashes[req.TxHash] {
		txHashMu.Unlock()
		writeJSON(w, http.StatusConflict, errorResponse("duplicate_deposit", "tx_hash has already been processed"))
		return
	}
	s.processedTxHashes[req.TxHash] = true
	txHashMu.Unlock()

	// Credit the verified amount from the on-chain transfer
	amountMicroUSD := verifyResp.AmountMicroUSD
	if err := s.ledger.Deposit(consumerKey, amountMicroUSD); err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to credit balance"))
		return
	}

	amountUSD := fmt.Sprintf("%.6f", float64(amountMicroUSD)/1_000_000)

	s.logger.Info("deposit credited (on-chain verified)",
		"consumer_key", consumerKey[:8]+"...",
		"wallet_address", req.WalletAddress,
		"tx_hash", req.TxHash,
		"amount_micro_usd", amountMicroUSD,
		"from", verifyResp.From,
	)

	writeJSON(w, http.StatusOK, map[string]any{
		"status":            "deposited",
		"verified":          true,
		"wallet_address":    req.WalletAddress,
		"tx_hash":           req.TxHash,
		"amount_usd":        amountUSD,
		"amount_micro_usd":  amountMicroUSD,
		"balance_micro_usd": s.ledger.Balance(consumerKey),
	})
}

// withdrawRequest is the JSON body for POST /v1/payments/withdraw.
type withdrawRequest struct {
	WalletAddress string `json:"wallet_address"`
	AmountUSD     string `json:"amount_usd"`
}

// settlementWithdrawResponse is the JSON response from the settlement service.
type settlementWithdrawResponse struct {
	ToAddress      string `json:"toAddress"`
	AmountMicroUSD int64  `json:"amountMicroUSD"`
	TxHash         string `json:"txHash"`
	Success        bool   `json:"success"`
	Error          string `json:"error,omitempty"`
}

// handleWithdraw handles POST /v1/payments/withdraw.
//
// Debits the consumer's ledger balance and sends pathUSD via the settlement
// service. If the on-chain transfer fails, the balance is re-credited.
func (s *Server) handleWithdraw(w http.ResponseWriter, r *http.Request) {
	var req withdrawRequest
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

	amountFloat, err := strconv.ParseFloat(req.AmountUSD, 64)
	if err != nil || amountFloat <= 0 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "amount_usd must be a positive number"))
		return
	}

	amountMicroUSD := int64(amountFloat * 1_000_000)
	consumerKey := consumerKeyFromContext(r.Context())

	// Check and debit balance
	if err := s.ledger.Charge(consumerKey, amountMicroUSD, "withdraw:"+req.WalletAddress); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("insufficient_funds", err.Error()))
		return
	}

	// Call settlement service to send on-chain
	withdrawBody, _ := json.Marshal(map[string]any{
		"to_address":       req.WalletAddress,
		"amount_micro_usd": amountMicroUSD,
		"reason":           "consumer_withdrawal",
		"private_key":      "", // In production, loaded from secure config/HSM
	})
	resp, err := http.Post(
		s.settlementURL+"/v1/settlement/withdraw",
		"application/json",
		bytes.NewReader(withdrawBody),
	)
	if err != nil {
		// Settlement service unreachable — re-credit the balance
		s.logger.Error("settlement service unreachable for withdrawal, re-crediting", "error", err)
		_ = s.ledger.Deposit(consumerKey, amountMicroUSD)
		writeJSON(w, http.StatusBadGateway, errorResponse("settlement_error", "settlement service unreachable"))
		return
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		s.logger.Error("failed to read settlement withdrawal response", "error", err)
		_ = s.ledger.Deposit(consumerKey, amountMicroUSD)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to read settlement response"))
		return
	}

	var withdrawResp settlementWithdrawResponse
	if err := json.Unmarshal(body, &withdrawResp); err != nil {
		s.logger.Error("failed to parse settlement withdrawal response", "error", err)
		_ = s.ledger.Deposit(consumerKey, amountMicroUSD)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to parse settlement response"))
		return
	}

	if !withdrawResp.Success {
		// On-chain transfer failed — re-credit the balance
		s.logger.Error("on-chain withdrawal failed, re-crediting",
			"error", withdrawResp.Error,
			"wallet_address", req.WalletAddress,
		)
		_ = s.ledger.Deposit(consumerKey, amountMicroUSD)
		writeJSON(w, http.StatusBadGateway, errorResponse("settlement_error", "on-chain transfer failed: "+withdrawResp.Error))
		return
	}

	s.logger.Info("withdrawal processed",
		"consumer_key", consumerKey[:8]+"...",
		"wallet_address", req.WalletAddress,
		"amount_micro_usd", amountMicroUSD,
		"tx_hash", withdrawResp.TxHash,
	)

	writeJSON(w, http.StatusOK, map[string]any{
		"status":            "withdrawn",
		"wallet_address":    req.WalletAddress,
		"amount_usd":        req.AmountUSD,
		"amount_micro_usd":  amountMicroUSD,
		"tx_hash":           withdrawResp.TxHash,
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
	if walletPayouts == nil {
		walletPayouts = []payments.Payout{}
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"wallet_address":         wallet,
		"balance_micro_usd":     balance,
		"balance_usd":           fmt.Sprintf("%.6f", float64(balance)/1_000_000),
		"total_earned_micro_usd": totalEarned,
		"total_earned_usd":      fmt.Sprintf("%.6f", float64(totalEarned)/1_000_000),
		"total_jobs":            totalJobs,
		"payouts":               walletPayouts,
		"ledger":                history,
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
