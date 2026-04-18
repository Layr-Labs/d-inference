package api

import (
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

	"crypto/rand"
	"encoding/base64"

	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
	"github.com/coder/websocket"
)

func testServer(t *testing.T) (*Server, *store.MemoryStore) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	return srv, st
}

func TestHealthEndpoint(t *testing.T) {
	srv, _ := testServer(t)

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("status = %d, want %d", w.Code, http.StatusOK)
	}

	var body map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if body["status"] != "ok" {
		t.Errorf("status = %v, want ok", body["status"])
	}
}

func TestHealthNoAuthRequired(t *testing.T) {
	srv, _ := testServer(t)

	// No Authorization header.
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("health should not require auth, got status %d", w.Code)
	}
}

func TestChatCompletionsNoAuth(t *testing.T) {
	srv, _ := testServer(t)

	body := `{"model":"test","messages":[{"role":"user","content":"hi"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
}

func TestChatCompletionsInvalidKey(t *testing.T) {
	srv, _ := testServer(t)

	body := `{"model":"test","messages":[{"role":"user","content":"hi"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer wrong-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
}

func TestChatCompletionsInvalidJSON(t *testing.T) {
	srv, _ := testServer(t)

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader("{bad"))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want %d", w.Code, http.StatusBadRequest)
	}
}

func TestChatCompletionsMissingModel(t *testing.T) {
	srv, _ := testServer(t)

	body := `{"messages":[{"role":"user","content":"hi"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want %d", w.Code, http.StatusBadRequest)
	}
}

func TestChatCompletionsMissingMessages(t *testing.T) {
	srv, _ := testServer(t)

	body := `{"model":"test"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want %d", w.Code, http.StatusBadRequest)
	}
}

func TestChatCompletionsNoProvider(t *testing.T) {
	srv, _ := testServer(t)

	// Set a catalog so the unknown model returns 404 immediately instead of
	// blocking for the full 120s queue timeout.
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: "known-model"}})

	body := `{"model":"nonexistent-model","messages":[{"role":"user","content":"hi"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusNotFound {
		t.Errorf("status = %d, want %d", w.Code, http.StatusNotFound)
	}
}

func TestListModelsWithAuth(t *testing.T) {
	srv, _ := testServer(t)

	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("status = %d, want %d", w.Code, http.StatusOK)
	}

	var body map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if body["object"] != "list" {
		t.Errorf("object = %v, want list", body["object"])
	}
}

func TestListModelsNoAuth(t *testing.T) {
	srv, _ := testServer(t)

	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
}

func TestCORSHeaders(t *testing.T) {
	srv, _ := testServer(t)

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Header().Get("Access-Control-Allow-Origin") != "*" {
		t.Errorf("CORS origin = %q, want *", w.Header().Get("Access-Control-Allow-Origin"))
	}
}

func TestCORSPreflight(t *testing.T) {
	srv, _ := testServer(t)

	req := httptest.NewRequest(http.MethodOptions, "/v1/chat/completions", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusNoContent {
		t.Errorf("status = %d, want %d", w.Code, http.StatusNoContent)
	}
}

// testPublicKeyB64 generates a random 32-byte X25519 public key for tests.
func testPublicKeyB64() string {
	key := make([]byte, 32)
	rand.Read(key)
	return base64.StdEncoding.EncodeToString(key)
}

// TestStreamingE2E sets up a full end-to-end streaming test with a simulated
// provider connected via WebSocket.
//
//nolint:gocognit
func TestStreamingE2E(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	// Start an httptest server.
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	// Connect a fake provider via WebSocket.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Send register message (with public key — encryption is mandatory).
	regMsg := protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel: "Mac15,8",
			ChipName:     "Apple M3 Max",
			MemoryGB:     64,
		},
		Models: []protocol.ModelInfo{
			{ID: "test-model", SizeBytes: 1000, ModelType: "test", Quantization: "4bit"},
		},
		Backend:   "test",
		PublicKey: testPublicKeyB64(),
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}

	// Give the server a moment to process registration.
	time.Sleep(100 * time.Millisecond)

	// Upgrade provider to hardware trust and mark challenge as verified
	// so it's eligible for routing (FindProviderWithTrust requires a
	// recent LastChallengeVerified).
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	// Start a goroutine to handle inference on the provider side.
	// The provider must handle the immediate attestation challenge that
	// fires on registration before the inference request arrives.
	providerDone := make(chan struct{})
	go func() {
		defer close(providerDone)
		var inferReq protocol.InferenceRequestMessage
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				t.Errorf("provider read: %v", err)
				return
			}
			// Check if this is a challenge — respond and continue reading.
			var raw map[string]interface{}
			if err := json.Unmarshal(data, &raw); err == nil {
				if raw["type"] == protocol.TypeAttestationChallenge {
					resp := protocol.AttestationResponseMessage{
						Type:      protocol.TypeAttestationResponse,
						Nonce:     raw["nonce"].(string),
						PublicKey: "dummy",
						Signature: "dummy",
					}
					respData, _ := json.Marshal(resp)
					conn.Write(ctx, websocket.MessageText, respData)
					continue
				}
			}
			// Otherwise it's the inference request.
			if err := json.Unmarshal(data, &inferReq); err != nil {
				t.Errorf("unmarshal inference request: %v", err)
				return
			}
			break
		}

		// Send two chunks.
		for _, word := range []string{"Hello", " world"} {
			chunk := protocol.InferenceResponseChunkMessage{
				Type:      protocol.TypeInferenceResponseChunk,
				RequestID: inferReq.RequestID,
				Data:      `data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"` + word + `"}}]}` + "\n\n",
			}
			chunkData, _ := json.Marshal(chunk)
			if err := conn.Write(ctx, websocket.MessageText, chunkData); err != nil {
				t.Errorf("write chunk: %v", err)
				return
			}
		}

		// Send complete.
		complete := protocol.InferenceCompleteMessage{
			Type:      protocol.TypeInferenceComplete,
			RequestID: inferReq.RequestID,
			Usage:     protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 5},
		}
		completeData, _ := json.Marshal(complete)
		if err := conn.Write(ctx, websocket.MessageText, completeData); err != nil {
			t.Errorf("write complete: %v", err)
			return
		}
	}()

	// Send a streaming chat completion request as a consumer.
	chatBody := `{"model":"test-model","messages":[{"role":"user","content":"hi"}],"stream":true}`
	httpReq, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(chatBody))
	httpReq.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status = %d, body = %s", resp.StatusCode, body)
	}

	if ct := resp.Header.Get("Content-Type"); ct != "text/event-stream" {
		t.Errorf("content-type = %q, want text/event-stream", ct)
	}

	// Read the full SSE response.
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}

	responseStr := string(body)
	if !strings.Contains(responseStr, "Hello") {
		t.Errorf("response should contain 'Hello', got: %s", responseStr)
	}
	if !strings.Contains(responseStr, "world") {
		t.Errorf("response should contain 'world', got: %s", responseStr)
	}
	if !strings.Contains(responseStr, "[DONE]") {
		t.Errorf("response should end with [DONE], got: %s", responseStr)
	}

	<-providerDone

	// Verify usage was recorded.
	records := st.UsageRecords()
	if len(records) != 1 {
		t.Fatalf("usage records = %d, want 1", len(records))
	}
	if records[0].PromptTokens != 10 {
		t.Errorf("prompt_tokens = %d, want 10", records[0].PromptTokens)
	}
	if records[0].CompletionTokens != 5 {
		t.Errorf("completion_tokens = %d, want 5", records[0].CompletionTokens)
	}
}

// TestNonStreamingE2E tests a non-streaming completion request.
func TestNonStreamingE2E(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Register (with public key — encryption is mandatory).
	regMsg := protocol.RegisterMessage{
		Type:      protocol.TypeRegister,
		Hardware:  protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64},
		Models:    []protocol.ModelInfo{{ID: "test-model", ModelType: "test", Quantization: "4bit"}},
		Backend:   "test",
		PublicKey: testPublicKeyB64(),
	}
	regData, _ := json.Marshal(regMsg)
	conn.Write(ctx, websocket.MessageText, regData)
	time.Sleep(100 * time.Millisecond)

	// Upgrade provider to hardware trust and mark challenge as verified
	// so it's eligible for routing (FindProviderWithTrust requires a
	// recent LastChallengeVerified).
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	// Provider goroutine — handles immediate challenge, then inference.
	providerDone := make(chan struct{})
	go func() {
		defer close(providerDone)
		var inferReq protocol.InferenceRequestMessage
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				t.Errorf("provider read: %v", err)
				return
			}
			var raw map[string]interface{}
			if err := json.Unmarshal(data, &raw); err == nil {
				if raw["type"] == protocol.TypeAttestationChallenge {
					resp := protocol.AttestationResponseMessage{
						Type:      protocol.TypeAttestationResponse,
						Nonce:     raw["nonce"].(string),
						PublicKey: "dummy",
						Signature: "dummy",
					}
					respData, _ := json.Marshal(resp)
					conn.Write(ctx, websocket.MessageText, respData)
					continue
				}
			}
			json.Unmarshal(data, &inferReq)
			break
		}

		// Send one chunk with the full content.
		chunk := protocol.InferenceResponseChunkMessage{
			Type:      protocol.TypeInferenceResponseChunk,
			RequestID: inferReq.RequestID,
			Data:      `data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"Hello world"}}]}` + "\n\n",
		}
		chunkData, _ := json.Marshal(chunk)
		conn.Write(ctx, websocket.MessageText, chunkData)

		// Complete.
		complete := protocol.InferenceCompleteMessage{
			Type:      protocol.TypeInferenceComplete,
			RequestID: inferReq.RequestID,
			Usage:     protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 2},
		}
		completeData, _ := json.Marshal(complete)
		conn.Write(ctx, websocket.MessageText, completeData)
	}()

	// Non-streaming request.
	chatBody := `{"model":"test-model","messages":[{"role":"user","content":"hi"}],"stream":false}`
	httpReq, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(chatBody))
	httpReq.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status = %d, body = %s", resp.StatusCode, body)
	}

	var result map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	choices, ok := result["choices"].([]any)
	if !ok || len(choices) == 0 {
		t.Fatalf("no choices in response: %v", result)
	}
	choice := choices[0].(map[string]any)
	message := choice["message"].(map[string]any)
	content := message["content"].(string)

	if content != "Hello world" {
		t.Errorf("content = %q, want %q", content, "Hello world")
	}

	<-providerDone
}

func TestExtractMessage(t *testing.T) {
	chunks := []string{
		"data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n",
		"data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"delta\":{\"content\":\" world\"}}]}\n\n",
	}

	msg := extractMessage(chunks)
	if msg.Content != "Hello world" {
		t.Errorf("content = %q, want %q", msg.Content, "Hello world")
	}
	if len(msg.ToolCalls) != 0 {
		t.Errorf("tool_calls = %v, want empty", msg.ToolCalls)
	}
}

func TestExtractMessageEmpty(t *testing.T) {
	msg := extractMessage(nil)
	if msg.Content != "" {
		t.Errorf("content = %q, want empty", msg.Content)
	}
}

func TestExtractMessageWithToolCalls(t *testing.T) {
	chunks := []string{
		`data: {"choices":[{"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"get_weather","arguments":""}}]}}]}`,
		`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"lo"}}]}}]}`,
		`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"cation\":"}}]}}]}`,
		`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"SF\"}"}}]}}]}`,
	}

	msg := extractMessage(chunks)
	if msg.Content != "" {
		t.Errorf("content = %q, want empty", msg.Content)
	}
	if len(msg.ToolCalls) != 1 {
		t.Fatalf("tool_calls length = %d, want 1", len(msg.ToolCalls))
	}
	tc := msg.ToolCalls[0]
	if tc["id"] != "call_abc" {
		t.Errorf("tool_call id = %v, want call_abc", tc["id"])
	}
	fn := tc["function"].(map[string]any)
	if fn["name"] != "get_weather" {
		t.Errorf("function name = %v, want get_weather", fn["name"])
	}
	if fn["arguments"] != `{"location":"SF"}` {
		t.Errorf("function arguments = %v, want {\"location\":\"SF\"}", fn["arguments"])
	}
}

func TestNormalizeSSEChunk(t *testing.T) {
	tests := []struct {
		name       string
		input      string
		wantChecks func(t *testing.T, got string)
	}{
		{
			name:  "null content becomes empty string",
			input: `data: {"choices":[{"delta":{"content":null}}]}`,
			wantChecks: func(t *testing.T, got string) {
				if !strings.Contains(got, `"content":""`) {
					t.Errorf("expected content to be empty string, got: %s", got)
				}
			},
		},
		{
			name:  "null tool_calls becomes empty array",
			input: `data: {"choices":[{"delta":{"content":"hi","tool_calls":null}}]}`,
			wantChecks: func(t *testing.T, got string) {
				if !strings.Contains(got, `"tool_calls":[]`) {
					t.Errorf("expected tool_calls to be empty array, got: %s", got)
				}
			},
		},
		{
			name:  "usage null is removed entirely",
			input: `data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":null,"reasoning":null,"tool_calls":null,"reasoning_content":null},"finish_reason":null}],"usage":null}`,
			wantChecks: func(t *testing.T, got string) {
				if strings.Contains(got, `"usage"`) {
					t.Errorf("expected usage to be removed, got: %s", got)
				}
				if !strings.Contains(got, `"content":""`) {
					t.Errorf("expected content to be empty string, got: %s", got)
				}
				if !strings.Contains(got, `"reasoning":""`) {
					t.Errorf("expected reasoning to be empty string, got: %s", got)
				}
				if !strings.Contains(got, `"tool_calls":[]`) {
					t.Errorf("expected tool_calls to be empty array, got: %s", got)
				}
				// reasoning_content should be removed (merged into reasoning)
				// to avoid ForgeCode serde duplicate-field errors.
				if strings.Contains(got, `"reasoning_content"`) {
					t.Errorf("expected reasoning_content to be removed (deduped into reasoning), got: %s", got)
				}
			},
		},
		{
			name:  "no nulls returns unchanged",
			input: `data: {"choices":[{"delta":{"content":"hello"}}]}`,
			wantChecks: func(t *testing.T, got string) {
				if got != `data: {"choices":[{"delta":{"content":"hello"}}]}` {
					t.Errorf("expected unchanged, got: %s", got)
				}
			},
		},
		{
			name:  "valid usage object is preserved",
			input: `data: {"id":"1","choices":[],"usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8}}`,
			wantChecks: func(t *testing.T, got string) {
				if !strings.Contains(got, `"prompt_tokens"`) {
					t.Errorf("expected usage to be preserved, got: %s", got)
				}
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := normalizeSSEChunk(tt.input)
			tt.wantChecks(t, got)
		})
	}
}

func TestExtractMessageWithNullFields(t *testing.T) {
	// Simulates real vllm-mlx chunks where the first chunk has null content
	// and subsequent chunks have actual content.
	chunks := []string{
		`data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"role":"assistant","content":null},"finish_reason":null}]}`,
		`data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}`,
		`data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":" world"},"finish_reason":"stop"}]}`,
	}

	msg := extractMessage(chunks)
	if msg.Content != "Hello world" {
		t.Errorf("content = %q, want %q", msg.Content, "Hello world")
	}
}

// TestProviderEarningsEndpoint verifies the /v1/provider/earnings endpoint
// returns balance and payout info for a provider wallet address.
func TestProviderEarningsEndpoint(t *testing.T) {
	srv, st := testServer(t)

	// Credit a provider wallet directly (simulates inference completion flow)
	providerWallet := "0xProviderWallet1234567890abcdef1234567890"
	_ = st.Credit(providerWallet, 450_000, store.LedgerPayout, "job-1") // $0.45
	_ = st.Credit(providerWallet, 900_000, store.LedgerPayout, "job-2") // $0.90

	// Query earnings — no auth required
	req := httptest.NewRequest(http.MethodGet, "/v1/provider/earnings?wallet="+providerWallet, nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", w.Code, w.Body.String())
	}

	var resp map[string]any
	json.Unmarshal(w.Body.Bytes(), &resp)

	if resp["wallet_address"] != providerWallet {
		t.Errorf("wallet_address = %v, want %v", resp["wallet_address"], providerWallet)
	}

	// Balance should be 450,000 + 900,000 = 1,350,000 micro-USD
	balance := resp["balance_micro_usd"].(float64)
	if balance != 1_350_000 {
		t.Errorf("balance_micro_usd = %v, want 1350000", balance)
	}

	balanceUSD := resp["balance_usd"].(string)
	if balanceUSD != "1.350000" {
		t.Errorf("balance_usd = %v, want 1.350000", balanceUSD)
	}

	// Should have ledger entries
	ledger := resp["ledger"].([]any)
	if len(ledger) != 2 {
		t.Errorf("ledger entries = %d, want 2", len(ledger))
	}
}

func TestProviderEarningsUsesStoredPayoutRecords(t *testing.T) {
	srv, _ := testServer(t)

	wallet := "0xStoredPayoutWallet1234567890abcdef1234"
	if err := srv.ledger.CreditProvider(wallet, 250_000, "qwen3.5-9b", "job-stored"); err != nil {
		t.Fatalf("CreditProvider: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/earnings?wallet="+wallet, nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", w.Code, w.Body.String())
	}

	var resp map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	payouts, ok := resp["payouts"].([]any)
	if !ok || len(payouts) != 1 {
		t.Fatalf("payouts = %#v, want single payout", resp["payouts"])
	}

	payout, ok := payouts[0].(map[string]any)
	if !ok {
		t.Fatalf("payout = %#v, want object", payouts[0])
	}
	if payout["model"] != "qwen3.5-9b" {
		t.Errorf("payout model = %v, want qwen3.5-9b", payout["model"])
	}
	if settled, _ := payout["settled"].(bool); settled {
		t.Errorf("payout settled = %v, want false", payout["settled"])
	}
}

// ---------------------------------------------------------------------------
// Benchmarks for normalizeSSEChunk (called per SSE chunk in streaming path)
// ---------------------------------------------------------------------------

func BenchmarkNormalizeSSEChunk_NoNulls(b *testing.B) {
	b.ReportAllocs()
	// Fast path: no null fields, function should return early.
	chunk := `data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1700000000,"model":"qwen3.5-27b","choices":[{"index":0,"delta":{"content":"Hello world"},"finish_reason":null}]}`

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = normalizeSSEChunk(chunk)
	}
}

func BenchmarkNormalizeSSEChunk_WithNulls(b *testing.B) {
	b.ReportAllocs()
	// Slow path: has null content, tool_calls, reasoning_content that need fixing.
	chunk := `data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1700000000,"model":"qwen3.5-27b","choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":null,"reasoning_content":null},"finish_reason":null}],"usage":null,"system_fingerprint":null}`

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = normalizeSSEChunk(chunk)
	}
}

func BenchmarkNormalizeSSEChunk_Usage(b *testing.B) {
	b.ReportAllocs()
	// Final chunk with usage object (should be preserved, not removed).
	chunk := `data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1700000000,"model":"qwen3.5-27b","choices":[],"usage":{"prompt_tokens":150,"completion_tokens":83,"total_tokens":233}}`

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = normalizeSSEChunk(chunk)
	}
}

func TestProviderEarningsNoWallet(t *testing.T) {
	srv, _ := testServer(t)

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/earnings", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", w.Code)
	}
}

func TestProviderEarningsViaHeader(t *testing.T) {
	srv, st := testServer(t)

	wallet := "0xHeaderWallet0000000000000000000000000000"
	_ = st.Credit(wallet, 100_000, store.LedgerPayout, "job-h1")

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/earnings", nil)
	req.Header.Set("X-Provider-Wallet", wallet)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}

	var resp map[string]any
	json.Unmarshal(w.Body.Bytes(), &resp)

	if resp["balance_micro_usd"].(float64) != 100_000 {
		t.Errorf("balance_micro_usd = %v, want 100000", resp["balance_micro_usd"])
	}
}

func TestProviderEarningsEmptyWallet(t *testing.T) {
	srv, _ := testServer(t)

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/earnings?wallet=0xNewWallet", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}

	var resp map[string]any
	json.Unmarshal(w.Body.Bytes(), &resp)

	if resp["balance_micro_usd"].(float64) != 0 {
		t.Errorf("balance_micro_usd = %v, want 0", resp["balance_micro_usd"])
	}
	if resp["total_jobs"].(float64) != 0 {
		t.Errorf("total_jobs = %v, want 0", resp["total_jobs"])
	}
}
