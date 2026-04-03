package api

// OpenAI API compatibility tests for the DGInf coordinator.
//
// These tests verify that the coordinator's HTTP responses match the OpenAI API
// specification for chat completions (streaming and non-streaming), model listing,
// error responses, authentication, request validation, and usage tracking.

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/dginf/coordinator/internal/protocol"
	"github.com/dginf/coordinator/internal/registry"
	"github.com/dginf/coordinator/internal/store"
	"nhooyr.io/websocket"
)

// testServerFastQueue creates a test server with a queue that times out in
// 100ms instead of the default 30s. Use this for tests that verify error
// responses for unavailable models to avoid blocking for 30s per test.
func testServerFastQueue(t *testing.T) (*Server, *store.MemoryStore) {
	t.Helper()
	srv, st := testServer(t)
	srv.registry.SetQueue(registry.NewRequestQueue(10, 100*time.Millisecond))
	return srv, st
}

// setupE2ETest creates a server with a connected, trusted provider that handles
// attestation challenges and serves inference requests via the given handler.
// Returns the httptest server, cleanup func, and a channel that the provider
// goroutine closes when done.
func setupE2ETest(t *testing.T, model string, handler func(ctx context.Context, conn *websocket.Conn, inferReq protocol.InferenceRequestMessage)) (*httptest.Server, func(), <-chan struct{}) {
	t.Helper()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	ts := httptest.NewServer(srv.Handler())

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		cancel()
		ts.Close()
		t.Fatalf("websocket dial: %v", err)
	}

	pubKey := testPublicKeyB64()
	regMsg := protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel: "Mac15,8",
			ChipName:     "Apple M3 Max",
			MemoryGB:     64,
		},
		Models:    []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
		Backend:   "test",
		PublicKey: pubKey,
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		cancel()
		ts.Close()
		t.Fatalf("write register: %v", err)
	}
	time.Sleep(150 * time.Millisecond)

	// Trust the provider and mark challenge as verified so it is routable.
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	providerDone := make(chan struct{})
	go func() {
		defer close(providerDone)
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			json.Unmarshal(data, &env)

			if env.Type == protocol.TypeAttestationChallenge {
				resp := makeValidChallengeResponse(data, pubKey)
				conn.Write(ctx, websocket.MessageText, resp)
				continue
			}
			if env.Type == protocol.TypeInferenceRequest {
				var inferReq protocol.InferenceRequestMessage
				json.Unmarshal(data, &inferReq)
				handler(ctx, conn, inferReq)
				return
			}
		}
	}()

	cleanup := func() {
		cancel()
		conn.Close(websocket.StatusNormalClosure, "")
		ts.Close()
	}

	return ts, cleanup, providerDone
}

// sendChunk is a helper to send an SSE chunk via the provider WebSocket.
func sendChunk(ctx context.Context, conn *websocket.Conn, requestID, sseData string) {
	chunk := protocol.InferenceResponseChunkMessage{
		Type:      protocol.TypeInferenceResponseChunk,
		RequestID: requestID,
		Data:      sseData,
	}
	data, _ := json.Marshal(chunk)
	conn.Write(ctx, websocket.MessageText, data)
}

// sendComplete is a helper to send an inference complete message.
func sendComplete(ctx context.Context, conn *websocket.Conn, requestID string, usage protocol.UsageInfo) {
	complete := protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: requestID,
		Usage:     usage,
	}
	data, _ := json.Marshal(complete)
	conn.Write(ctx, websocket.MessageText, data)
}

// --------------------------------------------------------------------------
// Test 1: Streaming chat completion format
// --------------------------------------------------------------------------

func TestOpenAI_ChatCompletionStreamingFormat(t *testing.T) {
	ts, cleanup, providerDone := setupE2ETest(t, "test-model", func(ctx context.Context, conn *websocket.Conn, inferReq protocol.InferenceRequestMessage) {
		// Send 3 chunks + complete.
		sendChunk(ctx, conn, inferReq.RequestID,
			`data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","created":1700000000,"model":"test-model","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}`+"\n\n")
		sendChunk(ctx, conn, inferReq.RequestID,
			`data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","created":1700000000,"model":"test-model","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}`+"\n\n")
		sendChunk(ctx, conn, inferReq.RequestID,
			`data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","created":1700000000,"model":"test-model","choices":[{"index":0,"delta":{"content":" world"},"finish_reason":"stop"}]}`+"\n\n")
		sendComplete(ctx, conn, inferReq.RequestID, protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 3})
	})
	defer cleanup()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	body := `{"model":"test-model","messages":[{"role":"user","content":"hi"}],"stream":true}`
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		t.Fatalf("status = %d, want 200, body = %s", resp.StatusCode, respBody)
	}

	// Verify Content-Type.
	if ct := resp.Header.Get("Content-Type"); ct != "text/event-stream" {
		t.Errorf("Content-Type = %q, want %q", ct, "text/event-stream")
	}

	// Parse SSE events.
	scanner := bufio.NewScanner(resp.Body)
	var events []string
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "data: ") {
			events = append(events, line)
		}
	}

	if len(events) < 4 {
		t.Fatalf("expected at least 4 SSE events (3 chunks + [DONE]), got %d: %v", len(events), events)
	}

	// Last event must be [DONE].
	lastEvent := events[len(events)-1]
	if lastEvent != "data: [DONE]" {
		t.Errorf("last event = %q, want %q", lastEvent, "data: [DONE]")
	}

	// Verify each data chunk (excluding [DONE]) is valid JSON with required fields.
	for i, event := range events {
		if event == "data: [DONE]" {
			continue
		}
		jsonStr := strings.TrimPrefix(event, "data: ")

		var chunk map[string]any
		if err := json.Unmarshal([]byte(jsonStr), &chunk); err != nil {
			t.Errorf("event %d: invalid JSON: %v (data: %s)", i, err, jsonStr)
			continue
		}

		// Must have id.
		if _, ok := chunk["id"]; !ok {
			t.Errorf("event %d: missing 'id' field", i)
		}

		// Must have object = "chat.completion.chunk".
		if obj, _ := chunk["object"].(string); obj != "chat.completion.chunk" {
			t.Errorf("event %d: object = %q, want %q", i, obj, "chat.completion.chunk")
		}

		// Must have choices array.
		choices, ok := chunk["choices"].([]any)
		if !ok {
			t.Errorf("event %d: missing or invalid 'choices' array", i)
			continue
		}

		for j, c := range choices {
			choice, ok := c.(map[string]any)
			if !ok {
				t.Errorf("event %d, choice %d: not an object", i, j)
				continue
			}
			// Must have index.
			if _, ok := choice["index"]; !ok {
				t.Errorf("event %d, choice %d: missing 'index'", i, j)
			}
			// Must have delta object.
			if _, ok := choice["delta"].(map[string]any); !ok {
				t.Errorf("event %d, choice %d: missing or invalid 'delta' object", i, j)
			}
		}

		// Check finish_reason on the last data chunk (not [DONE]).
		isLastDataChunk := (i == len(events)-2) // second to last, before [DONE]
		if isLastDataChunk && len(choices) > 0 {
			choice := choices[0].(map[string]any)
			fr, _ := choice["finish_reason"].(string)
			if fr != "stop" {
				t.Errorf("last data chunk: finish_reason = %q, want %q", fr, "stop")
			}
		}
	}

	<-providerDone
}

// --------------------------------------------------------------------------
// Test 2: Non-streaming chat completion format
// --------------------------------------------------------------------------

func TestOpenAI_ChatCompletionNonStreamingFormat(t *testing.T) {
	ts, cleanup, providerDone := setupE2ETest(t, "test-model", func(ctx context.Context, conn *websocket.Conn, inferReq protocol.InferenceRequestMessage) {
		sendChunk(ctx, conn, inferReq.RequestID,
			`data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"Hello world"}}]}`+"\n\n")
		sendComplete(ctx, conn, inferReq.RequestID, protocol.UsageInfo{PromptTokens: 8, CompletionTokens: 3})
	})
	defer cleanup()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	body := `{"model":"test-model","messages":[{"role":"user","content":"hi"}],"stream":false}`
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		t.Fatalf("status = %d, want 200, body = %s", resp.StatusCode, respBody)
	}

	// Verify Content-Type.
	if ct := resp.Header.Get("Content-Type"); ct != "application/json" {
		t.Errorf("Content-Type = %q, want %q", ct, "application/json")
	}

	var result map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	// id must start with "chatcmpl-".
	id, _ := result["id"].(string)
	if !strings.HasPrefix(id, "chatcmpl-") {
		t.Errorf("id = %q, want prefix %q", id, "chatcmpl-")
	}

	// object must be "chat.completion".
	if obj, _ := result["object"].(string); obj != "chat.completion" {
		t.Errorf("object = %q, want %q", obj, "chat.completion")
	}

	// choices array.
	choices, ok := result["choices"].([]any)
	if !ok || len(choices) == 0 {
		t.Fatalf("missing or empty 'choices': %v", result["choices"])
	}

	choice := choices[0].(map[string]any)

	// index.
	if idx, ok := choice["index"].(float64); !ok || idx != 0 {
		t.Errorf("choice.index = %v, want 0", choice["index"])
	}

	// message with role and content.
	msg, ok := choice["message"].(map[string]any)
	if !ok {
		t.Fatalf("choice.message missing or invalid")
	}
	if msg["role"] != "assistant" {
		t.Errorf("message.role = %v, want %q", msg["role"], "assistant")
	}
	if _, ok := msg["content"].(string); !ok {
		t.Errorf("message.content missing or not a string: %v", msg["content"])
	}

	// finish_reason.
	if fr, _ := choice["finish_reason"].(string); fr != "stop" {
		t.Errorf("finish_reason = %q, want %q", fr, "stop")
	}

	// usage object.
	usage, ok := result["usage"].(map[string]any)
	if !ok {
		t.Fatalf("missing 'usage' object")
	}
	if _, ok := usage["prompt_tokens"].(float64); !ok {
		t.Error("usage.prompt_tokens missing or not a number")
	}
	if _, ok := usage["completion_tokens"].(float64); !ok {
		t.Error("usage.completion_tokens missing or not a number")
	}
	if _, ok := usage["total_tokens"].(float64); !ok {
		t.Error("usage.total_tokens missing or not a number")
	}

	<-providerDone
}

// --------------------------------------------------------------------------
// Test 3: List models format
// --------------------------------------------------------------------------

func TestOpenAI_ListModelsFormat(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Connect a provider with a model.
	pubKey := testPublicKeyB64()
	conn := connectProvider(t, ctx, ts.URL,
		[]protocol.ModelInfo{{ID: "gpt-test", ModelType: "chat", Quantization: "4bit"}},
		pubKey)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Trust the provider.
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", w.Code, w.Body.String())
	}

	var result map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	// object = "list".
	if result["object"] != "list" {
		t.Errorf("object = %v, want %q", result["object"], "list")
	}

	// data array.
	data, ok := result["data"].([]any)
	if !ok {
		t.Fatalf("data is not an array: %T", result["data"])
	}

	if len(data) == 0 {
		t.Fatal("data array is empty, expected at least 1 model")
	}

	for i, item := range data {
		model, ok := item.(map[string]any)
		if !ok {
			t.Errorf("data[%d] is not an object", i)
			continue
		}

		// Each model must have id.
		if _, ok := model["id"].(string); !ok {
			t.Errorf("data[%d]: missing or invalid 'id'", i)
		}

		// object = "model".
		if model["object"] != "model" {
			t.Errorf("data[%d]: object = %v, want %q", i, model["object"], "model")
		}

		// created (timestamp, may be 0).
		if _, ok := model["created"].(float64); !ok {
			t.Errorf("data[%d]: missing or invalid 'created' timestamp", i)
		}

		// owned_by.
		if _, ok := model["owned_by"].(string); !ok {
			t.Errorf("data[%d]: missing or invalid 'owned_by'", i)
		}
	}
}

// --------------------------------------------------------------------------
// Test 4: Error response format
// --------------------------------------------------------------------------

func TestOpenAI_ErrorFormat(t *testing.T) {
	srv, _ := testServerFastQueue(t)

	// Request with a model that no provider serves.
	body := `{"model":"nonexistent-model-xyz","messages":[{"role":"user","content":"hi"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	// Should be 503 (no provider available).
	if w.Code != http.StatusServiceUnavailable {
		t.Errorf("status = %d, want %d", w.Code, http.StatusServiceUnavailable)
	}

	var result map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatalf("decode error response: %v", err)
	}

	// Must have top-level "error" object.
	errObj, ok := result["error"].(map[string]any)
	if !ok {
		t.Fatalf("response missing 'error' object: %v", result)
	}

	// error.message must be a non-empty string.
	msg, ok := errObj["message"].(string)
	if !ok || msg == "" {
		t.Errorf("error.message missing or empty: %v", errObj["message"])
	}

	// error.type must be a non-empty string.
	errType, ok := errObj["type"].(string)
	if !ok || errType == "" {
		t.Errorf("error.type missing or empty: %v", errObj["type"])
	}
}

// --------------------------------------------------------------------------
// Test 5: Auth required
// --------------------------------------------------------------------------

func TestOpenAI_AuthRequired(t *testing.T) {
	srv, _ := testServer(t)

	t.Run("no_auth_header", func(t *testing.T) {
		body := `{"model":"test","messages":[{"role":"user","content":"hi"}]}`
		req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)

		if w.Code != http.StatusUnauthorized {
			t.Errorf("status = %d, want %d", w.Code, http.StatusUnauthorized)
		}

		// Verify error format.
		var result map[string]any
		if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
			t.Fatalf("decode: %v", err)
		}
		errObj, ok := result["error"].(map[string]any)
		if !ok {
			t.Fatalf("missing 'error' object in 401 response: %v", result)
		}
		if _, ok := errObj["message"].(string); !ok {
			t.Error("error.message missing in 401 response")
		}
		if _, ok := errObj["type"].(string); !ok {
			t.Error("error.type missing in 401 response")
		}
	})

	t.Run("invalid_key", func(t *testing.T) {
		body := `{"model":"test","messages":[{"role":"user","content":"hi"}]}`
		req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer wrong-key-12345")
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)

		if w.Code != http.StatusUnauthorized {
			t.Errorf("status = %d, want %d", w.Code, http.StatusUnauthorized)
		}

		var result map[string]any
		if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
			t.Fatalf("decode: %v", err)
		}
		errObj, ok := result["error"].(map[string]any)
		if !ok {
			t.Fatalf("missing 'error' object in 401 response: %v", result)
		}
		if _, ok := errObj["message"].(string); !ok {
			t.Error("error.message missing in 401 response")
		}
		if _, ok := errObj["type"].(string); !ok {
			t.Error("error.type missing in 401 response")
		}
	})

	t.Run("list_models_no_auth", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)

		if w.Code != http.StatusUnauthorized {
			t.Errorf("status = %d, want %d", w.Code, http.StatusUnauthorized)
		}
	})
}

// --------------------------------------------------------------------------
// Test 6: Request validation
// --------------------------------------------------------------------------

func TestOpenAI_RequestValidation(t *testing.T) {
	srv, _ := testServerFastQueue(t)

	tests := []struct {
		name       string
		body       string
		wantStatus int
	}{
		{
			name:       "missing_model",
			body:       `{"messages":[{"role":"user","content":"hi"}]}`,
			wantStatus: http.StatusBadRequest,
		},
		{
			name:       "missing_messages",
			body:       `{"model":"test"}`,
			wantStatus: http.StatusBadRequest,
		},
		{
			name:       "empty_messages",
			body:       `{"model":"test","messages":[]}`,
			wantStatus: http.StatusBadRequest,
		},
		{
			name:       "invalid_json",
			body:       `{not valid json`,
			wantStatus: http.StatusBadRequest,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(tt.body))
			req.Header.Set("Authorization", "Bearer test-key")
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, req)

			if w.Code != tt.wantStatus {
				t.Errorf("status = %d, want %d, body = %s", w.Code, tt.wantStatus, w.Body.String())
			}

			// All validation errors should return OpenAI-format error.
			var result map[string]any
			if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
				t.Fatalf("response is not valid JSON: %v", err)
			}
			errObj, ok := result["error"].(map[string]any)
			if !ok {
				t.Fatalf("missing 'error' object: %v", result)
			}
			if _, ok := errObj["message"].(string); !ok {
				t.Error("error.message missing")
			}
			if _, ok := errObj["type"].(string); !ok {
				t.Error("error.type missing")
			}
		})
	}

	// Unusual role should pass validation (provider handles it).
	t.Run("unusual_role_passes_through", func(t *testing.T) {
		body := `{"model":"nonexistent","messages":[{"role":"custom_role","content":"hi"}]}`
		req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer test-key")
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)

		// Should NOT be 400 — the coordinator does not validate roles.
		// It will be 503 because no provider serves "nonexistent" model.
		if w.Code == http.StatusBadRequest {
			t.Errorf("unusual role should not cause 400, got %d", w.Code)
		}
	})
}

// --------------------------------------------------------------------------
// Test 7: Usage tracking
// --------------------------------------------------------------------------

func TestOpenAI_UsageTracking(t *testing.T) {
	promptTokens := 15
	completionTokens := 7
	expectedTotal := promptTokens + completionTokens

	ts, cleanup, providerDone := setupE2ETest(t, "usage-model", func(ctx context.Context, conn *websocket.Conn, inferReq protocol.InferenceRequestMessage) {
		sendChunk(ctx, conn, inferReq.RequestID,
			`data: {"id":"chatcmpl-u","choices":[{"delta":{"content":"test response"}}]}`+"\n\n")
		sendComplete(ctx, conn, inferReq.RequestID, protocol.UsageInfo{
			PromptTokens:     promptTokens,
			CompletionTokens: completionTokens,
		})
	})
	defer cleanup()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	body := `{"model":"usage-model","messages":[{"role":"user","content":"count tokens"}],"stream":false}`
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		t.Fatalf("status = %d, want 200, body = %s", resp.StatusCode, respBody)
	}

	var result map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		t.Fatalf("decode: %v", err)
	}

	usage, ok := result["usage"].(map[string]any)
	if !ok {
		t.Fatalf("missing 'usage' object in response: %v", result)
	}

	gotPrompt := int(usage["prompt_tokens"].(float64))
	gotCompletion := int(usage["completion_tokens"].(float64))
	gotTotal := int(usage["total_tokens"].(float64))

	if gotPrompt != promptTokens {
		t.Errorf("prompt_tokens = %d, want %d", gotPrompt, promptTokens)
	}
	if gotCompletion != completionTokens {
		t.Errorf("completion_tokens = %d, want %d", gotCompletion, completionTokens)
	}
	if gotTotal != expectedTotal {
		t.Errorf("total_tokens = %d, want %d (prompt + completion)", gotTotal, expectedTotal)
	}

	// Verify the arithmetic: total = prompt + completion.
	if gotTotal != gotPrompt+gotCompletion {
		t.Errorf("total_tokens (%d) != prompt_tokens (%d) + completion_tokens (%d)", gotTotal, gotPrompt, gotCompletion)
	}

	<-providerDone
}
