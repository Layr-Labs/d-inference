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
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/dginf/coordinator/internal/auth"
	"github.com/dginf/coordinator/internal/e2e"
	"github.com/dginf/coordinator/internal/payments"
	"github.com/dginf/coordinator/internal/protocol"
	"github.com/dginf/coordinator/internal/registry"
	"github.com/dginf/coordinator/internal/store"
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

// genericInferenceRequest captures any inference request body as raw JSON.
// Used for /v1/completions and /v1/messages endpoints where we pass the
// body through to the provider without parsing the endpoint-specific fields.
type genericInferenceRequest struct {
	Model  string `json:"model"`
	Stream bool   `json:"stream"`
	// RawBody is the complete request JSON, forwarded as-is to the provider.
	RawBody json.RawMessage `json:"-"`
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

	// Pre-flight balance check — reject requests from consumers with zero
	// balance before routing to a provider. This avoids wasting provider GPU
	// time on requests that can't be charged. Only enforced when the billing
	// service is configured (production); skipped in test/dev without billing.
	if s.billing != nil {
		consumerKey := consumerKeyFromContext(r.Context())
		if s.ledger.Balance(consumerKey) <= 0 {
			writeJSON(w, http.StatusPaymentRequired, errorResponse("insufficient_funds",
				"your balance is $0.00 — add funds at /billing before making requests"))
			return
		}
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
	// Snapshot mutable provider fields under lock to avoid racing with
	// background goroutines (MDA verification, challenge-response, heartbeat).
	provider.Mu().Lock()
	pubKey := provider.PublicKey
	attested := provider.Attested
	trustLevel := provider.TrustLevel
	attestResult := provider.AttestationResult
	mdaVerified := provider.MDAVerified
	provider.Mu().Unlock()

	// Immutable after registration — safe without lock.
	providerID := provider.ID
	chipName := provider.Hardware.ChipName
	machineModel := provider.Hardware.MachineModel

	if pubKey != "" {
		w.Header().Set("X-Provider-Public-Key", pubKey)
	}

	// Include attestation status headers so consumers know the trust
	// properties of the provider that served their request.
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

	// Build the upload URL for the provider to POST generated images to.
	// Derive from the incoming request's Host header.
	scheme := "https"
	if r.TLS == nil {
		scheme = "http"
	}
	uploadURL := fmt.Sprintf("%s://%s/v1/provider/image-upload?request_id=%s", scheme, r.Host, requestID)

	wireMsg := map[string]any{
		"type":       protocol.TypeImageGenerationRequest,
		"request_id": requestID,
		"upload_url": uploadURL,
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
			// Normalize null fields to match the OpenAI spec (some backends
			// like vllm-mlx send "content":null instead of "content":"").
			chunk = normalizeSSEChunk(chunk)
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

	stream, _ := parsed["stream"].(bool)

	// Inject the endpoint so the provider knows which local path to forward to.
	parsed["endpoint"] = endpoint

	var requestedTrust registry.TrustLevel
	if trustParam := r.URL.Query().Get("trust_level"); trustParam != "" {
		requestedTrust = registry.TrustLevel(trustParam)
	}

	provider := s.registry.FindProviderWithTrust(model, requestedTrust)
	if provider == nil {
		queuedReq := &registry.QueuedRequest{
			RequestID:  uuid.New().String(),
			Model:      model,
			ResponseCh: make(chan *registry.Provider, 1),
		}
		if err := s.registry.Queue().Enqueue(queuedReq); err != nil {
			writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_not_available",
				fmt.Sprintf("no provider available for model %q", model)))
			return
		}
		provider, err = s.registry.Queue().WaitForProvider(queuedReq)
		if err != nil {
			writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_not_available",
				fmt.Sprintf("no provider became available for model %q", model)))
			return
		}
	}

	requestID := uuid.New().String()
	inferenceBody, _ := json.Marshal(parsed)

	if provider.PublicKey == "" {
		s.registry.SetProviderIdle(provider.ID)
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("encryption_required",
			"no provider with E2E encryption available"))
		return
	}

	providerPubKey, err := e2e.ParsePublicKey(provider.PublicKey)
	if err != nil {
		s.registry.SetProviderIdle(provider.ID)
		writeJSON(w, http.StatusInternalServerError, errorResponse("encryption_error", "provider public key invalid"))
		return
	}

	sessionKeys, err := e2e.GenerateSessionKeys()
	if err != nil {
		s.registry.SetProviderIdle(provider.ID)
		writeJSON(w, http.StatusInternalServerError, errorResponse("encryption_error", "failed to generate session keys"))
		return
	}

	encrypted, err := e2e.Encrypt(inferenceBody, providerPubKey, sessionKeys)
	if err != nil {
		s.registry.SetProviderIdle(provider.ID)
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

	consumerKey := consumerKeyFromContext(r.Context())
	pr := &registry.PendingRequest{
		RequestID:   requestID,
		ProviderID:  provider.ID,
		Model:       model,
		ConsumerKey: consumerKey,
		ChunkCh:     make(chan string, chunkBufferSize),
		CompleteCh:  make(chan protocol.UsageInfo, 1),
		ErrorCh:     make(chan protocol.InferenceErrorMessage, 1),
	}
	pr.SessionPrivKey = &sessionKeys.PrivateKey
	provider.AddPending(pr)

	data, _ := json.Marshal(wireMsg)
	if err := provider.Conn.Write(r.Context(), websocket.MessageText, data); err != nil {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
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
