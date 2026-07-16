package api

// Edge case tests for the coordinator API.
//
// These tests verify that the coordinator handles malformed, missing, and
// boundary-condition inputs gracefully. All tests use mock providers
// (no real backends needed) and run in CI.

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

func TestEdge_ProviderEmptyModels(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Register a provider with no models
	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{}, testPublicKeyB64())
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Provider should register but not be findable for any model
	time.Sleep(200 * time.Millisecond)
	if p := findRoutableProvider(reg, "any-model"); p != nil {
		t.Error("provider with no models should not be findable")
	}
}

func TestEdge_ProviderDuplicateModelsRejected(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Register with duplicate model entries
	models := []protocol.ModelInfo{
		{ID: "dupe-model", ModelType: "chat", Quantization: "4bit"},
		{ID: "dupe-model", ModelType: "chat", Quantization: "4bit"},
		{ID: "dupe-model", ModelType: "chat", Quantization: "8bit"},
	}
	conn := connectProvider(t, ctx, ts.URL, models, testPublicKeyB64())
	defer conn.Close(websocket.StatusNormalClosure, "")

	time.Sleep(200 * time.Millisecond)
	// Ambiguous per-model capabilities are invalid: reject the entire
	// registration instead of silently choosing one duplicate.
	if reg.ProviderCount() != 0 {
		t.Errorf("expected duplicate registration rejection, got %d providers", reg.ProviderCount())
	}
}

func TestEdge_ProviderVeryLargeRegistration(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Register with many models
	var models []protocol.ModelInfo
	for i := range 100 {
		models = append(models, protocol.ModelInfo{
			ID:           fmt.Sprintf("model-%d", i),
			ModelType:    "chat",
			Quantization: "4bit",
		})
	}
	conn := connectProvider(t, ctx, ts.URL, models, testPublicKeyB64())
	defer conn.Close(websocket.StatusNormalClosure, "")

	time.Sleep(200 * time.Millisecond)
	if reg.ProviderCount() != 1 {
		t.Errorf("expected 1 provider, got %d", reg.ProviderCount())
	}
}

func TestEdge_CatalogChangeDuringActiveProvider(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = 100 * time.Millisecond

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	model := "dynamic-model"
	pubKey := testPublicKeyB64()
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}

	// No catalog set — model should be allowed
	conn := connectProvider(t, ctx, ts.URL, models, pubKey)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Handle the first challenge
	go handleProviderMessages(ctx, t, conn, func(msgType string, data []byte) []byte {
		if msgType == protocol.TypeAttestationChallenge {
			return makeValidChallengeResponse(data, pubKey)
		}
		return nil
	})

	time.Sleep(300 * time.Millisecond)

	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
	}

	// Model should be findable (no catalog = allow all)
	if p := findRoutableProvider(reg, model); p == nil {
		t.Fatal("provider should be findable with no catalog")
	}

	// Now set a catalog that excludes this model
	reg.SetModelCatalog([]registry.CatalogEntry{
		{ID: "other-model"},
	})

	// Model should now be rejected by catalog check
	if reg.IsModelInCatalog(model) {
		t.Error("model should not be in catalog after change")
	}
}

func TestEdge_ProviderSendsEmptyChunks(t *testing.T) {
	ts, cleanup, providerDone := setupE2ETest(t, "empty-chunk-model", func(ctx context.Context, conn *websocket.Conn, inferReq protocol.InferenceRequestMessage, providerPublicKey string) {
		// Send chunks with empty content
		sendChunk(t, ctx, conn, inferReq, providerPublicKey,
			`data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}`+"\n\n")
		sendChunk(t, ctx, conn, inferReq, providerPublicKey,
			`data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":""},"finish_reason":null}]}`+"\n\n")
		sendChunk(t, ctx, conn, inferReq, providerPublicKey,
			`data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"actual content"},"finish_reason":"stop"}]}`+"\n\n")
		sendComplete(ctx, conn, inferReq.RequestID, protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 1})
	})
	defer cleanup()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	body := `{"model":"empty-chunk-model","messages":[{"role":"user","content":"hi"}],"stream":true}`
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}

	// Read all SSE data — should not crash
	io.ReadAll(resp.Body)
	<-providerDone
}

func TestEdge_ProviderSendsVeryLargeChunk(t *testing.T) {
	// Simulate a provider sending a very large content chunk (100KB).
	largeContent := strings.Repeat("x", 100*1024)

	ts, cleanup, providerDone := setupE2ETest(t, "large-chunk-model", func(ctx context.Context, conn *websocket.Conn, inferReq protocol.InferenceRequestMessage, providerPublicKey string) {
		sendChunk(t, ctx, conn, inferReq, providerPublicKey,
			fmt.Sprintf(`data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":%q},"finish_reason":"stop"}]}`, largeContent)+"\n\n")
		sendComplete(ctx, conn, inferReq.RequestID, protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 25000})
	})
	defer cleanup()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	body := `{"model":"large-chunk-model","messages":[{"role":"user","content":"hi"}],"stream":true}`
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}

	respBody, _ := io.ReadAll(resp.Body)
	if len(respBody) < 100*1024 {
		t.Errorf("expected large response, got %d bytes", len(respBody))
	}

	<-providerDone
}

func TestEdge_ConcurrentRequestsSameProvider(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = 500 * time.Millisecond

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	model := "concurrent-model"
	pubKey := testPublicKeyB64()
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}

	conn := connectProvider(t, ctx, ts.URL, models, pubKey)
	defer conn.Close(websocket.StatusNormalClosure, "")

	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	// Provider serves requests in a loop
	served := make(chan int, 1)
	go func() {
		count := runProviderLoop(ctx, t, conn, pubKey, "concurrent-response")
		served <- count
	}()

	// Fire 5 concurrent requests
	const numRequests = 5
	var wg sync.WaitGroup
	results := make([]int, numRequests)

	for i := range numRequests {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			body := fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":"req %d"}],"stream":true}`, model, idx)
			req, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(body))
			req.Header.Set("Authorization", "Bearer test-key")

			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				results[idx] = 0
				return
			}
			io.ReadAll(resp.Body)
			resp.Body.Close()
			results[idx] = resp.StatusCode
		}(i)
	}

	wg.Wait()

	// At least one request should succeed (provider handles one at a time,
	// others may queue and succeed or time out)
	successCount := 0
	for _, code := range results {
		if code == 200 {
			successCount++
		}
	}
	if successCount == 0 {
		t.Errorf("no concurrent requests succeeded, results: %v", results)
	}
}

func TestEdge_ModelsEndpointNoProviders(t *testing.T) {
	srv, _ := testServer(t)

	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("models endpoint: status = %d, want 200", w.Code)
	}

	var resp struct {
		Object string `json:"object"`
		Data   []any  `json:"data"`
	}
	json.Unmarshal(w.Body.Bytes(), &resp)

	// With no providers connected, the models list is empty (the endpoint shows
	// available models from live providers), but the OpenAI list envelope must
	// still be well-formed. This also verifies the endpoint doesn't crash with
	// no providers or registry rows.
	if resp.Object != "list" {
		t.Errorf("object = %q, want list", resp.Object)
	}
}

func TestEdge_ProviderDisconnectMidStream(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	model := "disconnect-model"
	pubKey := testPublicKeyB64()
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}

	conn := connectProvider(t, ctx, ts.URL, models, pubKey)

	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	// Provider handles challenge then sends one chunk and disconnects
	go func() {
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
			}
			if env.Type == protocol.TypeInferenceRequest {
				var req protocol.InferenceRequestMessage
				json.Unmarshal(data, &req)

				// Send one chunk then disconnect abruptly
				sendChunk(t, ctx, conn, req, pubKey,
					`data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"partial"},"finish_reason":null}]}`+"\n\n")
				time.Sleep(50 * time.Millisecond)
				conn.Close(websocket.StatusAbnormalClosure, "simulated crash")
				return
			}
		}
	}()

	// Send a streaming request
	body := fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":"hi"}],"stream":true}`, model)
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer resp.Body.Close()

	// The response should complete (with error or partial data) rather than hang
	_, readErr := io.ReadAll(resp.Body)
	// Expect the body to be readable (not hang forever)
	_ = readErr

	// After provider disconnect, it should be removed from the registry
	time.Sleep(500 * time.Millisecond)
	if reg.ProviderCount() != 0 {
		t.Errorf("provider should be removed after disconnect, count = %d", reg.ProviderCount())
	}
}

func TestEdge_NonStreamingResponse(t *testing.T) {
	ts, cleanup, providerDone := setupE2ETest(t, "nonstream-model", func(ctx context.Context, conn *websocket.Conn, inferReq protocol.InferenceRequestMessage, providerPublicKey string) {
		// Provider sends a non-streaming response (single chunk with full content + complete)
		sendChunk(t, ctx, conn, inferReq, providerPublicKey,
			`data: {"id":"chatcmpl-ns","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"The answer is 42."},"finish_reason":"stop"}]}`+"\n\n")
		sendComplete(ctx, conn, inferReq.RequestID, protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 6})
	})
	defer cleanup()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	body := `{"model":"nonstream-model","messages":[{"role":"user","content":"What is the answer?"}],"stream":false}`
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		t.Fatalf("non-streaming: status = %d, body = %s", resp.StatusCode, respBody)
	}

	var result map[string]any
	json.NewDecoder(resp.Body).Decode(&result)

	// Should have choices array
	choices, _ := result["choices"].([]any)
	if len(choices) == 0 {
		t.Fatal("non-streaming response missing choices")
	}

	// Content-Type should be application/json (not text/event-stream)
	ct := resp.Header.Get("Content-Type")
	if !strings.Contains(ct, "application/json") {
		t.Errorf("non-streaming Content-Type = %q, want application/json", ct)
	}

	<-providerDone
}

func TestEdge_ProviderInvalidPublicKey(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Register with invalid base64 public key
	models := []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}}
	conn := connectProvider(t, ctx, ts.URL, models, "not-valid-base64!!!")
	defer conn.Close(websocket.StatusNormalClosure, "")

	time.Sleep(200 * time.Millisecond)
	// Provider should still register (key validation happens at encryption time)
	// but requests to it should fail gracefully
}

// suppress unused import warnings.
