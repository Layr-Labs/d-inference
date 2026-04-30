package api

// Consumer-facing API handlers for the Darkbloom coordinator.
//
// This file implements the OpenAI-compatible HTTP endpoints that consumers
// use to send inference requests. The coordinator acts as a trusted routing
// layer between consumers and providers.
//
// Trust model:
//   The coordinator runs in a Confidential VM, providing hardware-encrypted
//   memory. Consumers may additionally sender-seal requests to the
//   coordinator's X25519 key. The coordinator decrypts for routing purposes
//   but never logs prompt content, then re-encrypts each request to the
//   selected provider's X25519 public key before forwarding over the
//   WebSocket. Providers are attested via Secure Enclave challenge-response.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/darkbloom/coordinator/internal/auth"
	"github.com/darkbloom/coordinator/internal/e2e"
	"github.com/darkbloom/coordinator/internal/payments"
	"github.com/darkbloom/coordinator/internal/protocol"
	"github.com/darkbloom/coordinator/internal/registry"
	"github.com/darkbloom/coordinator/internal/store"
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

	// cancelWriteTimeout bounds how long a cancel write to the provider can
	// block. Using context.Background() unbounded here risks hanging the HTTP
	// handler goroutine when a WebSocket is half-dead.
	cancelWriteTimeout = 2 * time.Second
)

var thinkBlockPattern = regexp.MustCompile(`(?is)<think>(.*?)</think>\s*`)

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

func parseProviderSerialAllowlist(parsed map[string]any) ([]string, bool, error) {
	var rawValues []any
	provided := false
	for _, key := range []string{"provider_serial", "provider_serials"} {
		v, ok := parsed[key]
		if !ok {
			continue
		}
		provided = true
		switch x := v.(type) {
		case string:
			rawValues = append(rawValues, x)
		case []any:
			rawValues = append(rawValues, x...)
		default:
			return nil, true, fmt.Errorf("%s must be a string or array of strings", key)
		}
	}
	if !provided {
		return nil, false, nil
	}

	seen := make(map[string]struct{}, len(rawValues))
	ids := make([]string, 0, len(rawValues))
	for _, raw := range rawValues {
		id, ok := raw.(string)
		if !ok {
			return nil, true, fmt.Errorf("provider_serials must contain only strings")
		}
		id = strings.TrimSpace(id)
		if id == "" {
			continue
		}
		if _, exists := seen[id]; exists {
			continue
		}
		seen[id] = struct{}{}
		ids = append(ids, id)
	}
	if len(ids) == 0 {
		return nil, true, fmt.Errorf("provider_serials must include at least one provider serial")
	}
	return ids, true, nil
}

func stripProviderRoutingFields(parsed map[string]any) bool {
	changed := false
	for _, key := range []string{"provider_serial", "provider_serials"} {
		if _, ok := parsed[key]; ok {
			delete(parsed, key)
			changed = true
		}
	}
	return changed
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

func copyJSONMap(in map[string]any) map[string]any {
	out := make(map[string]any, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}

func responsesContentText(content any) string {
	switch c := content.(type) {
	case nil:
		return ""
	case string:
		return c
	case []any:
		parts := make([]string, 0, len(c))
		for _, part := range c {
			switch p := part.(type) {
			case string:
				if p != "" {
					parts = append(parts, p)
				}
			case map[string]any:
				if text, _ := p["text"].(string); text != "" {
					parts = append(parts, text)
					continue
				}
				if p["type"] == "input_image" || p["type"] == "input_file" {
					// Text models cannot consume binary Responses parts yet.
					// Preserve the turn shape without leaking URLs or blobs.
					parts = append(parts, fmt.Sprintf("[%s omitted]", p["type"]))
				}
			}
		}
		return strings.Join(parts, "\n")
	default:
		b, err := json.Marshal(c)
		if err != nil {
			return fmt.Sprint(c)
		}
		return string(b)
	}
}

func responsesInputToChatMessages(input any) ([]map[string]any, error) {
	switch v := input.(type) {
	case string:
		return []map[string]any{{"role": "user", "content": v}}, nil
	case []any:
		messages := make([]map[string]any, 0, len(v))
		for _, raw := range v {
			item, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			if typ, _ := item["type"].(string); typ != "" {
				switch typ {
				case "message":
					role, _ := item["role"].(string)
					if role == "" {
						role = "user"
					}
					if role == "developer" {
						role = "system"
					}
					messages = append(messages, map[string]any{
						"role":    role,
						"content": responsesContentText(item["content"]),
					})
				case "function_call":
					callID, _ := item["call_id"].(string)
					if callID == "" {
						callID, _ = item["id"].(string)
					}
					name, _ := item["name"].(string)
					args, _ := item["arguments"].(string)
					messages = append(messages, map[string]any{
						"role":    "assistant",
						"content": "",
						"tool_calls": []map[string]any{{
							"id":   callID,
							"type": "function",
							"function": map[string]any{
								"name":      name,
								"arguments": args,
							},
						}},
					})
				case "function_call_output":
					callID, _ := item["call_id"].(string)
					messages = append(messages, map[string]any{
						"role":         "tool",
						"tool_call_id": callID,
						"content":      responsesContentText(item["output"]),
					})
				case "reasoning":
					// Reasoning items are model-side metadata, not prompt text.
					continue
				default:
					return nil, fmt.Errorf("unsupported Responses input item type %q", typ)
				}
				continue
			}

			role, _ := item["role"].(string)
			if role == "" {
				continue
			}
			if role == "developer" {
				role = "system"
			}
			messages = append(messages, map[string]any{
				"role":    role,
				"content": responsesContentText(item["content"]),
			})
		}
		if len(messages) == 0 {
			return nil, fmt.Errorf("Responses input did not contain any chat-compatible messages")
		}
		return messages, nil
	default:
		return nil, fmt.Errorf("Responses input must be a string or array")
	}
}

func responsesToolsToChatTools(raw any) ([]any, error) {
	tools, ok := raw.([]any)
	if !ok || len(tools) == 0 {
		return nil, nil
	}
	out := make([]any, 0, len(tools))
	for _, rawTool := range tools {
		tool, ok := rawTool.(map[string]any)
		if !ok {
			continue
		}
		typ, _ := tool["type"].(string)
		if typ == "" || typ == "function" {
			name, _ := tool["name"].(string)
			if name == "" {
				if fn, _ := tool["function"].(map[string]any); fn != nil {
					out = append(out, tool)
					continue
				}
				return nil, fmt.Errorf("function tool is missing name")
			}
			fn := map[string]any{"name": name}
			if description, ok := tool["description"].(string); ok {
				fn["description"] = description
			}
			if parameters, ok := tool["parameters"]; ok {
				fn["parameters"] = parameters
			}
			out = append(out, map[string]any{
				"type":     "function",
				"function": fn,
			})
			continue
		}
		return nil, fmt.Errorf("unsupported Responses tool type %q", typ)
	}
	return out, nil
}

func responsesToolChoiceToChat(raw any) (any, error) {
	choice, ok := raw.(map[string]any)
	if !ok {
		return raw, nil
	}
	typ, _ := choice["type"].(string)
	if typ == "function" {
		name, _ := choice["name"].(string)
		if name == "" {
			return nil, fmt.Errorf("function tool_choice is missing name")
		}
		return map[string]any{
			"type": "function",
			"function": map[string]any{
				"name": name,
			},
		}, nil
	}
	return raw, nil
}

func responsesTextFormatToChatResponseFormat(raw any) any {
	text, ok := raw.(map[string]any)
	if !ok {
		return nil
	}
	format, ok := text["format"].(map[string]any)
	if !ok {
		return nil
	}
	switch format["type"] {
	case "json_object":
		return map[string]any{"type": "json_object"}
	case "json_schema":
		return map[string]any{
			"type":        "json_schema",
			"json_schema": format,
		}
	}
	return nil
}

func responsesRequestToChatCompletions(parsed map[string]any) (map[string]any, error) {
	messages, err := responsesInputToChatMessages(parsed["input"])
	if err != nil {
		return nil, err
	}

	out := copyJSONMap(parsed)
	delete(out, "input")
	delete(out, "endpoint")
	delete(out, "max_output_tokens")
	delete(out, "text")
	out["messages"] = messages
	if maxTokens := explicitMaxTokens(parsed); maxTokens > 0 {
		out["max_tokens"] = maxTokens
	}
	if tools, err := responsesToolsToChatTools(parsed["tools"]); err != nil {
		return nil, err
	} else if len(tools) > 0 {
		out["tools"] = tools
	}
	if choice, err := responsesToolChoiceToChat(parsed["tool_choice"]); err != nil {
		return nil, err
	} else if choice != nil {
		out["tool_choice"] = choice
	}
	if responseFormat := responsesTextFormatToChatResponseFormat(parsed["text"]); responseFormat != nil {
		out["response_format"] = responseFormat
	}
	return out, nil
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

	allowedProviderSerials, hasProviderAllowlist, err := parseProviderSerialAllowlist(parsed)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", err.Error()))
		return
	}
	if hasProviderAllowlist && stripProviderRoutingFields(parsed) {
		rawBody, _ = json.Marshal(parsed)
	}

	isResponsesAPI := input != nil && len(messages) == 0

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

	if isResponsesAPI {
		providerParsed, err := responsesRequestToChatCompletions(parsed)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", err.Error()))
			return
		}
		rawBody, _ = json.Marshal(providerParsed)
	}

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

	for attempt := range maxDispatchAttempts {
		requestID = uuid.New().String()
		pr = &registry.PendingRequest{
			RequestID:              requestID,
			Model:                  model,
			ConsumerKey:            consumerKey,
			IsResponsesAPI:         isResponsesAPI,
			EstimatedPromptTokens:  estimatedPromptTokens,
			RequestedMaxTokens:     requestedMaxTokens,
			AllowedProviderSerials: allowedProviderSerials,
			AcceptedCh:             make(chan struct{}, 1),
			ChunkCh:                make(chan string, chunkBufferSize),
			CompleteCh:             make(chan protocol.UsageInfo, 1),
			ErrorCh:                make(chan protocol.InferenceErrorMessage, 1),
		}

		var decision registry.RoutingDecision
		provider, decision = s.registry.ReserveProviderEx(model, pr, excludeList()...)
		if provider == nil {
			// On retry attempts, don't queue — if the only available
			// providers already failed, waiting 120s for one of them
			// to come back won't help. Break and return the last error.
			if attempt > 0 {
				outcome := "no_provider"
				if decision.CapacityRejections > 0 && decision.CandidateCount == 0 {
					// Every fitting candidate was rejected by the
					// admission gate (memory). Surface as over_capacity
					// so dashboards distinguish "no provider" from
					// "fleet over-subscribed for this model size".
					outcome = "over_capacity"
				}
				s.ddIncr("routing.decisions", []string{"model:" + model, "outcome:" + outcome})
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
				s.ddIncr("routing.decisions", []string{"model:" + model, "outcome:over_capacity"})
				refundReservation()
				writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_not_available", fmt.Sprintf("no hardware-trusted provider available for model %q and queue is full", model)))
				return
			}
			s.ddIncr("routing.decisions", []string{"model:" + model, "outcome:queued"})

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
				s.ddIncr("request_queue.timeout", []string{"model:" + model})
				writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_not_available", fmt.Sprintf("no hardware-trusted provider became available for model %q (queue timeout)", model)))
				return
			}
			decision = queuedReq.Decision
		}
		s.ddIncr("routing.decisions", []string{"model:" + model, "outcome:selected"})
		s.ddIncr("routing.provider_selected", []string{"provider_id:" + provider.ID, "model:" + model})
		s.ddHistogram("routing.cost_ms", decision.CostMs, []string{"model:" + model})
		if decision.EffectiveTPS > 0 {
			s.ddGauge("routing.effective_decode_tps", decision.EffectiveTPS, []string{"provider_id:" + provider.ID})
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
			"trace_id", requestIDFromContext(r.Context()),
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
			s.emitRequest(r.Context(), protocol.SeverityWarn, protocol.KindInferenceError, requestID,
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
		case <-timer.C:
			excludeProviders[provider.ID] = struct{}{}
			// Order matters: RemovePending must precede sendProviderCancel.
			// Each retry attempt generates a fresh requestID (line 301), so
			// the original provider would otherwise keep generating into
			// this requestID and could send InferenceComplete after the
			// retry has already been billed — double-charge. Removing the
			// pending entry first means any late chunk/Complete from the
			// original provider hits handleChunk/handleComplete with an
			// unknown request_id and is silently dropped, so only the
			// retry's Complete reaches the ledger.
			provider.RemovePending(requestID)
			s.registry.SetProviderIdle(provider.ID)
			s.sendProviderCancel(provider, requestID)
			lastErr = "timeout waiting for first response"
			lastErrCode = http.StatusGatewayTimeout
			s.logger.Warn("provider timeout, retrying",
				"request_id", requestID,
				"provider_id", provider.ID,
				"attempt", attempt+1,
			)
			s.emitRequest(r.Context(), protocol.SeverityWarn, protocol.KindInferenceError, requestID,
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
			provider.RemovePending(requestID)
			s.registry.SetProviderIdle(provider.ID)
			s.sendProviderCancel(provider, requestID)
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
						excludeProviders[provider.ID] = struct{}{}
						provider.RemovePending(requestID)
						s.registry.SetProviderIdle(provider.ID)
						lastErr = errMsg.Error
						lastErrCode = errMsg.StatusCode
						s.logger.Warn("provider failed after accepting request, retrying",
							"request_id", requestID,
							"provider_id", provider.ID,
							"attempt", attempt+1,
							"error", errMsg.Error,
						)
						s.emitRequest(r.Context(), protocol.SeverityWarn, protocol.KindInferenceError, requestID,
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
					default:
						committed = true
					}
				}
			case errMsg := <-pr.ErrorCh:
				chunkTimer.Stop()
				excludeProviders[provider.ID] = struct{}{}
				provider.RemovePending(requestID)
				s.registry.SetProviderIdle(provider.ID)
				lastErr = errMsg.Error
				lastErrCode = errMsg.StatusCode
				s.logger.Warn("provider failed after accepting request, retrying",
					"request_id", requestID,
					"provider_id", provider.ID,
					"attempt", attempt+1,
					"error", errMsg.Error,
				)
				s.emitRequest(r.Context(), protocol.SeverityWarn, protocol.KindInferenceError, requestID,
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
				provider.RemovePending(requestID)
				s.registry.SetProviderIdle(provider.ID)
				s.sendProviderCancel(provider, requestID)
				lastErr = "provider accepted but timed out before first chunk"
				lastErrCode = http.StatusGatewayTimeout
				s.logger.Warn("provider timed out after accepting request, retrying",
					"request_id", requestID,
					"provider_id", provider.ID,
					"attempt", attempt+1,
				)
				s.emitRequest(r.Context(), protocol.SeverityWarn, protocol.KindInferenceError, requestID,
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
				provider.RemovePending(requestID)
				s.registry.SetProviderIdle(provider.ID)
				s.sendProviderCancel(provider, requestID)
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
		s.emitRequest(r.Context(), protocol.SeverityError, protocol.KindInferenceError, requestID,
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
		writeJSON(w, statusCode, errorResponse("provider_error",
			fmt.Sprintf("inference failed after %d attempt(s): %s", maxDispatchAttempts, lastErr)))
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
	if pr.IsResponsesAPI {
		s.handleResponsesStreamingResponseWithFirstChunk(w, r, pr, firstChunk)
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

func writeResponsesSSE(w http.ResponseWriter, flusher http.Flusher, event map[string]any) {
	data, err := json.Marshal(event)
	if err != nil {
		return
	}
	fmt.Fprintf(w, "data: %s\n\n", data)
	flusher.Flush()
}

func (s *Server) handleResponsesStreamingResponseWithFirstChunk(w http.ResponseWriter, r *http.Request, pr *registry.PendingRequest, firstChunk string) {
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
	writeResponsesSSE(w, flusher, map[string]any{
		"type": "response.created",
		"response": map[string]any{
			"id":           responseID,
			"created_at":   createdAt,
			"model":        pr.Model,
			"service_tier": nil,
		},
	})

	chunks := make([]string, 0, 16)
	if firstChunk != "" {
		chunks = append(chunks, firstChunk)
	}

	timer := time.NewTimer(inferenceTimeout)
	defer timer.Stop()

	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if !ok {
				var usage protocol.UsageInfo
				select {
				case u, ok := <-pr.CompleteCh:
					if ok {
						usage = u
					}
				default:
				}
				msg := extractMessage(chunks)
				writeResponsesStreamOutput(w, flusher, pr, responseID, createdAt, msg, usage)
				return
			}
			chunks = append(chunks, chunk)
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			timer.Reset(inferenceTimeout)

		case errMsg := <-pr.ErrorCh:
			writeResponsesSSE(w, flusher, map[string]any{
				"type":            "error",
				"sequence_number": 0,
				"error": map[string]any{
					"type":    "provider_error",
					"code":    "provider_error",
					"message": errMsg.Error,
					"param":   nil,
				},
			})
			return

		case <-timer.C:
			writeResponsesSSE(w, flusher, map[string]any{
				"type":            "error",
				"sequence_number": 0,
				"error": map[string]any{
					"type":    "timeout",
					"code":    "timeout",
					"message": "request timed out",
					"param":   nil,
				},
			})
			return

		case <-r.Context().Done():
			return
		}
	}
}

func writeResponsesStreamOutput(w http.ResponseWriter, flusher http.Flusher, pr *registry.PendingRequest, responseID string, createdAt int64, msg extractedMessage, usage protocol.UsageInfo) {
	outputIndex := 0
	if msg.Reasoning != "" {
		itemID := responseItemID("rs", pr.RequestID, outputIndex)
		writeResponsesSSE(w, flusher, map[string]any{
			"type":         "response.output_item.added",
			"output_index": outputIndex,
			"item": map[string]any{
				"type":              "reasoning",
				"id":                itemID,
				"encrypted_content": nil,
			},
		})
		writeResponsesSSE(w, flusher, map[string]any{
			"type":          "response.reasoning_summary_part.added",
			"item_id":       itemID,
			"summary_index": 0,
		})
		writeResponsesSSE(w, flusher, map[string]any{
			"type":          "response.reasoning_summary_text.delta",
			"item_id":       itemID,
			"summary_index": 0,
			"delta":         msg.Reasoning,
		})
		writeResponsesSSE(w, flusher, map[string]any{
			"type":          "response.reasoning_summary_part.done",
			"item_id":       itemID,
			"summary_index": 0,
		})
		writeResponsesSSE(w, flusher, map[string]any{
			"type":         "response.output_item.done",
			"output_index": outputIndex,
			"item": map[string]any{
				"type":              "reasoning",
				"id":                itemID,
				"encrypted_content": nil,
			},
		})
		outputIndex++
	}

	if msg.Content != "" || len(msg.ToolCalls) == 0 {
		itemID := responseItemID("msg", pr.RequestID, outputIndex)
		writeResponsesSSE(w, flusher, map[string]any{
			"type":         "response.output_item.added",
			"output_index": outputIndex,
			"item": map[string]any{
				"type":  "message",
				"id":    itemID,
				"phase": nil,
			},
		})
		if msg.Content != "" {
			writeResponsesSSE(w, flusher, map[string]any{
				"type":         "response.output_text.delta",
				"item_id":      itemID,
				"output_index": outputIndex,
				"delta":        msg.Content,
			})
		}
		writeResponsesSSE(w, flusher, map[string]any{
			"type":         "response.output_item.done",
			"output_index": outputIndex,
			"item": map[string]any{
				"type":  "message",
				"id":    itemID,
				"phase": nil,
			},
		})
		outputIndex++
	}

	for _, tc := range msg.ToolCalls {
		fn, _ := tc["function"].(map[string]any)
		callID, _ := tc["id"].(string)
		if callID == "" {
			callID = responseItemID("call", pr.RequestID, outputIndex)
		}
		name, _ := fn["name"].(string)
		args, _ := fn["arguments"].(string)
		itemID := responseItemID("fc", pr.RequestID, outputIndex)
		writeResponsesSSE(w, flusher, map[string]any{
			"type":         "response.output_item.added",
			"output_index": outputIndex,
			"item": map[string]any{
				"type":      "function_call",
				"id":        itemID,
				"call_id":   callID,
				"name":      name,
				"arguments": "",
			},
		})
		if args != "" {
			writeResponsesSSE(w, flusher, map[string]any{
				"type":         "response.function_call_arguments.delta",
				"item_id":      itemID,
				"output_index": outputIndex,
				"delta":        args,
			})
		}
		writeResponsesSSE(w, flusher, map[string]any{
			"type":         "response.output_item.done",
			"output_index": outputIndex,
			"item": map[string]any{
				"type":      "function_call",
				"id":        itemID,
				"call_id":   callID,
				"name":      name,
				"arguments": args,
				"status":    "completed",
			},
		})
		outputIndex++
	}

	reasoningTokens := uint64(0)
	if msg.Reasoning != "" {
		reasoningTokens = uint64(usage.CompletionTokens)
	}
	writeResponsesSSE(w, flusher, map[string]any{
		"type": "response.completed",
		"response": map[string]any{
			"id":                 responseID,
			"created_at":         createdAt,
			"model":              pr.Model,
			"incomplete_details": nil,
			"usage":              responsesUsage(uint64(usage.PromptTokens), uint64(usage.CompletionTokens), reasoningTokens),
			"service_tier":       nil,
		},
	})
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
					if err := json.Unmarshal([]byte(raw), &obj); err == nil {
						objType, _ := obj["object"].(string)
						// Complete responses have object=chat.completion or
						// object=response. Delta chunks have object=chat.completion.chunk.
						if objType == "chat.completion" || objType == "response" {
							select {
							case <-pr.CompleteCh:
							case <-ctx.Done():
							}
							if objType == "chat.completion" {
								normalizeCompleteChatResponse(obj, pr.Model)
								if pr.IsResponsesAPI {
									obj = chatCompletionToResponses(obj, pr.Model, pr.SESignature, pr.ResponseHash)
									writeJSON(w, http.StatusOK, obj)
									return
								}
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
					var resp map[string]any
					if pr.IsResponsesAPI {
						resp = buildResponsesResponse(pr.RequestID, pr.Model, msg, usage, pr.SESignature, pr.ResponseHash)
					} else {
						resp = buildNonStreamingResponse(pr.RequestID, pr.Model, msg, usage, pr.SESignature, pr.ResponseHash)
					}
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

func normalizeCompleteChatResponse(obj map[string]any, requestedModel string) {
	if requestedModel != "" {
		obj["model"] = requestedModel
	}
	for _, key := range []string{"system_fingerprint"} {
		if v, ok := obj[key]; ok && v == nil {
			delete(obj, key)
		}
	}
	choices, ok := obj["choices"].([]any)
	if !ok {
		return
	}
	for _, rawChoice := range choices {
		choice, ok := rawChoice.(map[string]any)
		if !ok {
			continue
		}
		if message, ok := choice["message"].(map[string]any); ok {
			normalizeCompleteMessage(message)
		}
		if delta, ok := choice["delta"].(map[string]any); ok {
			normalizeCompleteMessage(delta)
		}
	}
}

func normalizeCompleteMessage(message map[string]any) {
	var extractedReasoning string
	if content, ok := message["content"]; !ok || content == nil {
		message["content"] = ""
	} else if contentText, ok := content.(string); ok {
		cleaned, reasoning := stripThinkBlocks(contentText)
		message["content"] = cleaned
		extractedReasoning = reasoning
	}

	if rc, ok := message["reasoning_content"]; ok {
		if rcText, ok := rc.(string); ok && rcText != "" {
			mergeReasoningField(message, rcText)
		}
		delete(message, "reasoning_content")
	}
	if reasoning, ok := message["reasoning"]; ok && reasoning == nil {
		delete(message, "reasoning")
	}
	if extractedReasoning != "" {
		mergeReasoningField(message, extractedReasoning)
	}
	for _, key := range []string{"tool_calls", "refusal"} {
		if v, ok := message[key]; ok && v == nil {
			delete(message, key)
		}
	}
}

func mergeReasoningField(message map[string]any, reasoning string) {
	reasoning = strings.TrimSpace(reasoning)
	if reasoning == "" {
		return
	}
	if existing, ok := message["reasoning"].(string); ok && strings.TrimSpace(existing) != "" {
		if existing != reasoning && !strings.Contains(existing, reasoning) {
			message["reasoning"] = existing + "\n\n" + reasoning
		}
		return
	}
	message["reasoning"] = reasoning
}

func stripThinkBlocks(text string) (string, string) {
	matches := thinkBlockPattern.FindAllStringSubmatch(text, -1)
	reasoningParts := make([]string, 0, len(matches)+1)
	found := len(matches) > 0
	for _, match := range matches {
		if len(match) > 1 {
			if part := strings.TrimSpace(match[1]); part != "" {
				reasoningParts = append(reasoningParts, part)
			}
		}
	}
	cleaned := thinkBlockPattern.ReplaceAllString(text, "")
	lower := strings.ToLower(cleaned)
	if idx := strings.Index(lower, "<think>"); idx >= 0 {
		found = true
		if part := strings.TrimSpace(cleaned[idx+len("<think>"):]); part != "" {
			reasoningParts = append(reasoningParts, part)
		}
		cleaned = cleaned[:idx]
	}
	if !found {
		return text, ""
	}
	return strings.TrimSpace(cleaned), strings.Join(reasoningParts, "\n\n")
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
				Content          string `json:"content"`
				Reasoning        string `json:"reasoning"`
				ReasoningContent string `json:"reasoning_content"`
				ToolCalls        []struct {
					Index    int    `json:"index"`
					ID       string `json:"id,omitempty"`
					Type     string `json:"type,omitempty"`
					Function struct {
						Name      string `json:"name,omitempty"`
						Arguments string `json:"arguments,omitempty"`
					} `json:"function,omitempty"`
				} `json:"tool_calls,omitempty"`
			} `json:"delta"`
			Message struct {
				Content          string `json:"content"`
				Reasoning        string `json:"reasoning"`
				ReasoningContent string `json:"reasoning_content"`
			} `json:"message"`
			FinishReason *string `json:"finish_reason"`
		}
		if err := json.Unmarshal(choicesRaw, &choices); err != nil {
			continue
		}

		for _, c := range choices {
			if c.Delta.Content != "" {
				contentBuilder.WriteString(c.Delta.Content)
			} else if c.Message.Content != "" {
				contentBuilder.WriteString(c.Message.Content)
			}
			if c.Delta.Reasoning != "" {
				reasoningBuilder.WriteString(c.Delta.Reasoning)
			} else if c.Delta.ReasoningContent != "" {
				reasoningBuilder.WriteString(c.Delta.ReasoningContent)
			} else if c.Message.Reasoning != "" {
				reasoningBuilder.WriteString(c.Message.Reasoning)
			} else if c.Message.ReasoningContent != "" {
				reasoningBuilder.WriteString(c.Message.ReasoningContent)
			}
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

	content := contentBuilder.String()
	reasoning := reasoningBuilder.String()
	if cleaned, extractedReasoning := stripThinkBlocks(content); extractedReasoning != "" {
		content = cleaned
		if strings.TrimSpace(reasoning) != "" {
			reasoning += "\n\n" + extractedReasoning
		} else {
			reasoning = extractedReasoning
		}
	}
	msg := extractedMessage{Content: content, Reasoning: reasoning}
	if len(toolCallMap) > 0 {
		msg.ToolCalls = make([]map[string]any, 0, len(toolCallMap))
		for i := range len(toolCallMap) {
			if tc, ok := toolCallMap[i]; ok {
				delete(tc, "index")
				msg.ToolCalls = append(msg.ToolCalls, tc)
			}
		}
	}
	return msg
}

func responsesUsage(promptTokens, completionTokens uint64, reasoningTokens uint64) map[string]any {
	return map[string]any{
		"input_tokens": promptTokens,
		"input_tokens_details": map[string]any{
			"cached_tokens": 0,
		},
		"output_tokens": completionTokens,
		"output_tokens_details": map[string]any{
			"reasoning_tokens": reasoningTokens,
		},
	}
}

func responsesIncompleteDetails(finishReason string) any {
	switch finishReason {
	case "length":
		return map[string]any{"reason": "max_output_tokens"}
	case "content_filter":
		return map[string]any{"reason": "content_filter"}
	default:
		return nil
	}
}

func responseItemID(prefix, requestID string, index int) string {
	return fmt.Sprintf("%s_%s_%d", prefix, strings.ReplaceAll(requestID, "-", ""), index)
}

func appendResponsesOutputItems(output []any, requestID string, msg extractedMessage) []any {
	index := len(output)
	if msg.Reasoning != "" {
		output = append(output, map[string]any{
			"type": "reasoning",
			"id":   responseItemID("rs", requestID, index),
			"summary": []map[string]any{{
				"type": "summary_text",
				"text": msg.Reasoning,
			}},
		})
		index++
	}
	if msg.Content != "" || len(msg.ToolCalls) == 0 {
		output = append(output, map[string]any{
			"type": "message",
			"role": "assistant",
			"id":   responseItemID("msg", requestID, index),
			"content": []map[string]any{{
				"type":        "output_text",
				"text":        msg.Content,
				"annotations": []any{},
			}},
		})
		index++
	}
	for _, tc := range msg.ToolCalls {
		fn, _ := tc["function"].(map[string]any)
		callID, _ := tc["id"].(string)
		if callID == "" {
			callID = responseItemID("call", requestID, index)
		}
		name, _ := fn["name"].(string)
		args, _ := fn["arguments"].(string)
		output = append(output, map[string]any{
			"type":      "function_call",
			"id":        responseItemID("fc", requestID, index),
			"call_id":   callID,
			"name":      name,
			"arguments": args,
		})
		index++
	}
	return output
}

func buildResponsesResponse(requestID, model string, msg extractedMessage, usage protocol.UsageInfo, seSignature, responseHash string) map[string]any {
	reasoningTokens := uint64(0)
	if msg.Reasoning != "" {
		reasoningTokens = uint64(usage.CompletionTokens)
	}
	resp := map[string]any{
		"id":         "resp_" + strings.ReplaceAll(requestID, "-", ""),
		"object":     "response",
		"created_at": time.Now().Unix(),
		"model":      model,
		"output":     appendResponsesOutputItems(nil, requestID, msg),
		"usage":      responsesUsage(uint64(usage.PromptTokens), uint64(usage.CompletionTokens), reasoningTokens),
	}
	if seSignature != "" {
		resp["se_signature"] = seSignature
		resp["response_hash"] = responseHash
	}
	return resp
}

func firstChoice(obj map[string]any) map[string]any {
	choices, _ := obj["choices"].([]any)
	if len(choices) == 0 {
		return nil
	}
	choice, _ := choices[0].(map[string]any)
	return choice
}

func stringFromMap(m map[string]any, keys ...string) string {
	for _, key := range keys {
		if s, _ := m[key].(string); s != "" {
			return s
		}
	}
	return ""
}

func chatUsageToResponsesUsage(obj map[string]any, reasoning string) map[string]any {
	usage, _ := obj["usage"].(map[string]any)
	promptTokens, _ := intFromRequestValue(usage["prompt_tokens"])
	completionTokens, _ := intFromRequestValue(usage["completion_tokens"])
	reasoningTokens := 0
	if reasoning != "" {
		reasoningTokens = completionTokens
	}
	return responsesUsage(uint64(promptTokens), uint64(completionTokens), uint64(reasoningTokens))
}

func chatCompletionToResponses(obj map[string]any, requestedModel, seSignature, responseHash string) map[string]any {
	requestID, _ := obj["id"].(string)
	requestID = strings.TrimPrefix(requestID, "chatcmpl-")
	if requestID == "" {
		requestID = uuid.NewString()
	}
	created, ok := intFromRequestValue(obj["created"])
	if !ok || created <= 0 {
		created = int(time.Now().Unix())
	}

	msg := extractedMessage{}
	finishReason := ""
	if choice := firstChoice(obj); choice != nil {
		finishReason, _ = choice["finish_reason"].(string)
		if message, _ := choice["message"].(map[string]any); message != nil {
			msg.Content = stringFromMap(message, "content")
			msg.Reasoning = stringFromMap(message, "reasoning", "reasoning_content")
			if rawToolCalls, _ := message["tool_calls"].([]any); len(rawToolCalls) > 0 {
				msg.ToolCalls = make([]map[string]any, 0, len(rawToolCalls))
				for _, rawTC := range rawToolCalls {
					if tc, _ := rawTC.(map[string]any); tc != nil {
						msg.ToolCalls = append(msg.ToolCalls, tc)
					}
				}
			}
		}
	}

	resp := map[string]any{
		"id":                 "resp_" + strings.ReplaceAll(requestID, "-", ""),
		"object":             "response",
		"created_at":         created,
		"model":              requestedModel,
		"output":             appendResponsesOutputItems(nil, requestID, msg),
		"incomplete_details": responsesIncompleteDetails(finishReason),
		"usage":              chatUsageToResponsesUsage(obj, msg.Reasoning),
	}
	if seSignature != "" {
		resp["se_signature"] = seSignature
		resp["response_hash"] = responseHash
	}
	return resp
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
		if cm.Active && !IsRetiredProviderModel(cm) {
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
			"owned_by": "darkbloom",
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

// handleRevokeKey handles DELETE /v1/auth/keys — revokes an API key.
// The caller must own the key (same account). Requires Privy auth so a
// compromised API key cannot revoke legitimate keys.
func (s *Server) handleRevokeKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		writeJSON(w, http.StatusUnauthorized, errorResponse("auth_error", "authentication required"))
		return
	}

	var body struct {
		Key string `json:"key"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Key == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("bad_request", "provide {\"key\": \"darkbloom-...\"}"))
		return
	}

	owner := s.store.GetKeyAccount(body.Key)
	if owner != user.AccountID {
		writeJSON(w, http.StatusForbidden, errorResponse("forbidden", "you can only revoke your own keys"))
		return
	}

	if !s.store.RevokeKey(body.Key) {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "key not found or already revoked"))
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"status": "revoked"})
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
	const cacheKey = "api_version:v1"
	if cached, ok := s.readCache.Get(cacheKey); ok {
		writeCachedJSON(w, http.StatusOK, cached)
		return
	}

	var resp map[string]any
	// Try release table first.
	if release := s.store.GetLatestRelease("macos-arm64"); release != nil {
		resp = map[string]any{
			"version":      release.Version,
			"download_url": release.URL,
			"bundle_hash":  release.BundleHash,
			"changelog":    release.Changelog,
		}
	} else {
		// Fallback to hardcoded version + coordinator download.
		scheme := "https"
		if r.TLS == nil && !strings.Contains(r.Host, "darkbloom.dev") {
			scheme = "http"
		}
		downloadURL := fmt.Sprintf("%s://%s/dl/darkbloom-bundle-macos-arm64.tar.gz", scheme, r.Host)
		resp = map[string]any{
			"version":      LatestProviderVersion,
			"download_url": downloadURL,
		}
	}
	body, err := json.Marshal(resp)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to encode version"))
		return
	}
	s.readCache.Set(cacheKey, body, time.Minute)
	writeCachedJSON(w, http.StatusOK, body)
}

// --- payment handlers ---

// handleBalance handles GET /v1/payments/balance.
// Returns the consumer's current balance in both micro-USD and USD.
func (s *Server) handleBalance(w http.ResponseWriter, r *http.Request) {
	consumerKey := consumerKeyFromContext(r.Context())
	balance := s.ledger.Balance(consumerKey)
	withdrawable := s.store.GetWithdrawableBalance(consumerKey)

	writeJSON(w, http.StatusOK, map[string]any{
		"balance_micro_usd":      balance,
		"balance_usd":            fmt.Sprintf("%.6f", float64(balance)/1_000_000),
		"withdrawable_micro_usd": withdrawable,
		"withdrawable_usd":       fmt.Sprintf("%.6f", float64(withdrawable)/1_000_000),
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
		RequestID:              requestID,
		Model:                  model,
		ConsumerKey:            consumerKey,
		AllowedProviderSerials: allowedProviderSerials,
		EstimatedPromptTokens:  estimatedPromptTokens,
		RequestedMaxTokens:     requestedMaxTokens,
		ReservedMicroUSD:       reservedMicroUSD,
		ChunkCh:                make(chan string, chunkBufferSize),
		CompleteCh:             make(chan protocol.UsageInfo, 1),
		ErrorCh:                make(chan protocol.InferenceErrorMessage, 1),
	}

	provider, decision := s.registry.ReserveProviderEx(model, pr)
	if provider == nil {
		queuedReq := &registry.QueuedRequest{
			RequestID:  requestID,
			Model:      model,
			Pending:    pr,
			ResponseCh: make(chan *registry.Provider, 1),
		}
		if err := s.registry.Queue().Enqueue(queuedReq); err != nil {
			refundReservation()
			s.ddIncr("routing.decisions", []string{"model:" + model, "outcome:over_capacity"})
			writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_not_available",
				fmt.Sprintf("no provider available for model %q", model)))
			return
		}
		s.ddIncr("routing.decisions", []string{"model:" + model, "outcome:queued"})
		provider, err = s.registry.Queue().WaitForProviderContext(r.Context(), queuedReq)
		if err != nil {
			if errors.Is(err, context.Canceled) {
				refundReservation()
				return
			}
			refundReservation()
			writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_not_available",
				fmt.Sprintf("no provider became available for model %q", model)))
			return
		}
		decision = queuedReq.Decision
	}
	s.ddIncr("routing.decisions", []string{"model:" + model, "outcome:selected"})
	s.ddIncr("routing.provider_selected", []string{"provider_id:" + provider.ID, "model:" + model})
	s.ddHistogram("routing.cost_ms", decision.CostMs, []string{"model:" + model})
	if decision.EffectiveTPS > 0 {
		s.ddGauge("routing.effective_decode_tps", decision.EffectiveTPS, []string{"provider_id:" + provider.ID})
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
