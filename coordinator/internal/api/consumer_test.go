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

	"github.com/dginf/coordinator/internal/protocol"
	"github.com/dginf/coordinator/internal/registry"
	"github.com/dginf/coordinator/internal/store"
	"nhooyr.io/websocket"
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

	body := `{"model":"nonexistent-model","messages":[{"role":"user","content":"hi"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusServiceUnavailable {
		t.Errorf("status = %d, want %d", w.Code, http.StatusServiceUnavailable)
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

	// Upgrade provider to hardware trust for routing eligibility.
	for _, id := range reg.ProviderIDs() {
		p := reg.GetProvider(id)
		if p != nil {
			p.TrustLevel = registry.TrustHardware
		}
	}

	// Start a goroutine to handle inference on the provider side.
	providerDone := make(chan struct{})
	go func() {
		defer close(providerDone)
		// Read the inference request.
		_, data, err := conn.Read(ctx)
		if err != nil {
			t.Errorf("provider read: %v", err)
			return
		}

		var inferReq protocol.InferenceRequestMessage
		if err := json.Unmarshal(data, &inferReq); err != nil {
			t.Errorf("unmarshal inference request: %v", err)
			return
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

	// Upgrade provider to hardware trust for routing eligibility.
	for _, id := range reg.ProviderIDs() {
		p := reg.GetProvider(id)
		if p != nil {
			p.TrustLevel = registry.TrustHardware
		}
	}

	// Provider goroutine.
	providerDone := make(chan struct{})
	go func() {
		defer close(providerDone)
		_, data, err := conn.Read(ctx)
		if err != nil {
			t.Errorf("provider read: %v", err)
			return
		}

		var inferReq protocol.InferenceRequestMessage
		json.Unmarshal(data, &inferReq)

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

func TestExtractContent(t *testing.T) {
	chunks := []string{
		"data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n",
		"data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"delta\":{\"content\":\" world\"}}]}\n\n",
	}

	content := extractContent(chunks)
	if content != "Hello world" {
		t.Errorf("content = %q, want %q", content, "Hello world")
	}
}

func TestExtractContentEmpty(t *testing.T) {
	content := extractContent(nil)
	if content != "" {
		t.Errorf("content = %q, want empty", content)
	}
}

// --- Settlement integration tests ---

// fakeSettlementServer creates a mock settlement service that returns the given
// verification and withdrawal responses.
func fakeSettlementServer(t *testing.T, verifyResp map[string]any, withdrawResp map[string]any) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()

	mux.HandleFunc("POST /v1/settlement/verify-deposit", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(verifyResp)
	})

	mux.HandleFunc("POST /v1/settlement/withdraw", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(withdrawResp)
	})

	return httptest.NewServer(mux)
}

func TestVerifiedDeposit(t *testing.T) {
	srv, _ := testServer(t)

	// Set up mock settlement service that verifies successfully
	settlement := fakeSettlementServer(t, map[string]any{
		"verified":       true,
		"txHash":         "0xabc123",
		"from":           "0x1111111111111111111111111111111111111111",
		"amount":         "5000000",
		"amountUSD":      "5.000000",
		"amountMicroUSD": float64(5_000_000),
		"blockNumber":    "12345",
	}, nil)
	defer settlement.Close()
	srv.SetSettlementURL(settlement.URL)

	body := `{"wallet_address":"0x1111111111111111111111111111111111111111","tx_hash":"0xabc123"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/payments/deposit", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d, body = %s", w.Code, http.StatusOK, w.Body.String())
	}

	var resp map[string]any
	json.Unmarshal(w.Body.Bytes(), &resp)

	if resp["verified"] != true {
		t.Errorf("verified = %v, want true", resp["verified"])
	}
	if resp["amount_micro_usd"].(float64) != 5_000_000 {
		t.Errorf("amount_micro_usd = %v, want 5000000", resp["amount_micro_usd"])
	}
}

func TestVerifiedDepositFailedVerification(t *testing.T) {
	srv, _ := testServer(t)

	settlement := fakeSettlementServer(t, map[string]any{
		"verified":       false,
		"error":          "Transaction failed",
		"amountMicroUSD": float64(0),
	}, nil)
	defer settlement.Close()
	srv.SetSettlementURL(settlement.URL)

	body := `{"wallet_address":"0x1111111111111111111111111111111111111111","tx_hash":"0xbad"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/payments/deposit", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want %d, body = %s", w.Code, http.StatusBadRequest, w.Body.String())
	}
}

func TestDoubleDepositPrevention(t *testing.T) {
	srv, _ := testServer(t)

	settlement := fakeSettlementServer(t, map[string]any{
		"verified":       true,
		"txHash":         "0xdouble",
		"from":           "0x1111111111111111111111111111111111111111",
		"amount":         "1000000",
		"amountUSD":      "1.000000",
		"amountMicroUSD": float64(1_000_000),
		"blockNumber":    "100",
	}, nil)
	defer settlement.Close()
	srv.SetSettlementURL(settlement.URL)

	// First deposit should succeed
	body := `{"wallet_address":"0x1111111111111111111111111111111111111111","tx_hash":"0xdouble"}`
	req1 := httptest.NewRequest(http.MethodPost, "/v1/payments/deposit", strings.NewReader(body))
	req1.Header.Set("Authorization", "Bearer test-key")
	w1 := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w1, req1)

	if w1.Code != http.StatusOK {
		t.Fatalf("first deposit status = %d, want %d", w1.Code, http.StatusOK)
	}

	// Second deposit with same tx_hash should fail
	req2 := httptest.NewRequest(http.MethodPost, "/v1/payments/deposit", strings.NewReader(body))
	req2.Header.Set("Authorization", "Bearer test-key")
	w2 := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w2, req2)

	if w2.Code != http.StatusConflict {
		t.Errorf("second deposit status = %d, want %d (conflict), body = %s", w2.Code, http.StatusConflict, w2.Body.String())
	}
}

func TestTrustBasedDepositStillWorks(t *testing.T) {
	srv, _ := testServer(t)

	// No tx_hash — trust-based deposit
	body := `{"wallet_address":"0x1111111111111111111111111111111111111111","amount_usd":"10.00"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/payments/deposit", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d, body = %s", w.Code, http.StatusOK, w.Body.String())
	}

	var resp map[string]any
	json.Unmarshal(w.Body.Bytes(), &resp)

	if resp["status"] != "deposited" {
		t.Errorf("status = %v, want deposited", resp["status"])
	}
	if resp["amount_micro_usd"].(float64) != 10_000_000 {
		t.Errorf("amount_micro_usd = %v, want 10000000", resp["amount_micro_usd"])
	}
}

func TestWithdrawSuccess(t *testing.T) {
	srv, _ := testServer(t)

	settlement := fakeSettlementServer(t, nil, map[string]any{
		"toAddress":      "0x2222222222222222222222222222222222222222",
		"amountMicroUSD": float64(3_000_000),
		"txHash":         "0xwithdraw123",
		"success":        true,
	})
	defer settlement.Close()
	srv.SetSettlementURL(settlement.URL)

	// First deposit some funds
	depositBody := `{"wallet_address":"0x1111","amount_usd":"10.00"}`
	depositReq := httptest.NewRequest(http.MethodPost, "/v1/payments/deposit", strings.NewReader(depositBody))
	depositReq.Header.Set("Authorization", "Bearer test-key")
	dw := httptest.NewRecorder()
	srv.Handler().ServeHTTP(dw, depositReq)

	if dw.Code != http.StatusOK {
		t.Fatalf("deposit status = %d, body = %s", dw.Code, dw.Body.String())
	}

	// Now withdraw
	withdrawBody := `{"wallet_address":"0x2222222222222222222222222222222222222222","amount_usd":"3.00"}`
	withdrawReq := httptest.NewRequest(http.MethodPost, "/v1/payments/withdraw", strings.NewReader(withdrawBody))
	withdrawReq.Header.Set("Authorization", "Bearer test-key")
	ww := httptest.NewRecorder()
	srv.Handler().ServeHTTP(ww, withdrawReq)

	if ww.Code != http.StatusOK {
		t.Fatalf("withdraw status = %d, want %d, body = %s", ww.Code, http.StatusOK, ww.Body.String())
	}

	var resp map[string]any
	json.Unmarshal(ww.Body.Bytes(), &resp)

	if resp["status"] != "withdrawn" {
		t.Errorf("status = %v, want withdrawn", resp["status"])
	}
	if resp["tx_hash"] != "0xwithdraw123" {
		t.Errorf("tx_hash = %v, want 0xwithdraw123", resp["tx_hash"])
	}
	// Balance should be 10.00 - 3.00 = 7.00 = 7,000,000 micro-USD
	if resp["balance_micro_usd"].(float64) != 7_000_000 {
		t.Errorf("balance_micro_usd = %v, want 7000000", resp["balance_micro_usd"])
	}
}

func TestWithdrawInsufficientFunds(t *testing.T) {
	srv, _ := testServer(t)

	// Try to withdraw without any balance
	body := `{"wallet_address":"0x2222222222222222222222222222222222222222","amount_usd":"5.00"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/payments/withdraw", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want %d, body = %s", w.Code, http.StatusBadRequest, w.Body.String())
	}
}

func TestWithdrawSettlementFailureRecredits(t *testing.T) {
	srv, _ := testServer(t)

	settlement := fakeSettlementServer(t, nil, map[string]any{
		"toAddress":      "0x2222222222222222222222222222222222222222",
		"amountMicroUSD": float64(3_000_000),
		"txHash":         "0x0",
		"success":        false,
		"error":          "Insufficient platform balance",
	})
	defer settlement.Close()
	srv.SetSettlementURL(settlement.URL)

	// Deposit some funds
	depositBody := `{"wallet_address":"0x1111","amount_usd":"10.00"}`
	depositReq := httptest.NewRequest(http.MethodPost, "/v1/payments/deposit", strings.NewReader(depositBody))
	depositReq.Header.Set("Authorization", "Bearer test-key")
	dw := httptest.NewRecorder()
	srv.Handler().ServeHTTP(dw, depositReq)

	// Try to withdraw — settlement will fail
	withdrawBody := `{"wallet_address":"0x2222222222222222222222222222222222222222","amount_usd":"3.00"}`
	withdrawReq := httptest.NewRequest(http.MethodPost, "/v1/payments/withdraw", strings.NewReader(withdrawBody))
	withdrawReq.Header.Set("Authorization", "Bearer test-key")
	ww := httptest.NewRecorder()
	srv.Handler().ServeHTTP(ww, withdrawReq)

	if ww.Code != http.StatusBadGateway {
		t.Errorf("withdraw status = %d, want %d, body = %s", ww.Code, http.StatusBadGateway, ww.Body.String())
	}

	// Check balance is re-credited — should still be 10.00
	balReq := httptest.NewRequest(http.MethodGet, "/v1/payments/balance", nil)
	balReq.Header.Set("Authorization", "Bearer test-key")
	bw := httptest.NewRecorder()
	srv.Handler().ServeHTTP(bw, balReq)

	var balResp map[string]any
	json.Unmarshal(bw.Body.Bytes(), &balResp)
	if balResp["balance_micro_usd"].(float64) != 10_000_000 {
		t.Errorf("balance after failed withdrawal = %v, want 10000000 (should be re-credited)", balResp["balance_micro_usd"])
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
