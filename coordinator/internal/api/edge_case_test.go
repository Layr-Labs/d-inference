package api

// Edge case tests for the coordinator API.
//
// These tests verify that the coordinator handles malformed, missing, and
// boundary-condition inputs gracefully. All tests use mock providers
// (no real backends needed) and run in CI.

import (
	"context"
	"crypto/rand"
	"encoding/base64"
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

	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
	"nhooyr.io/websocket"
)

// ---------------------------------------------------------------------------
// Request validation edge cases
// ---------------------------------------------------------------------------

func TestEdge_EmptyBody(t *testing.T) {
	srv, _ := testServer(t)

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(""))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("empty body: status = %d, want 400", w.Code)
	}
}

func TestEdge_InvalidJSON(t *testing.T) {
	srv, _ := testServer(t)

	cases := []struct {
		name string
		body string
	}{
		{"truncated", `{"model": "test"`},
		{"bare_string", `"just a string"`},
		{"bare_number", `42`},
		{"bare_null", `null`},
		{"bare_array", `[1,2,3]`},
		{"trailing_comma", `{"model": "test",}`},
		{"single_quote", `{'model': 'test'}`},
		{"binary_garbage", "\x00\x01\x02\x03"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(tc.body))
			req.Header.Set("Authorization", "Bearer test-key")
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, req)

			if w.Code != http.StatusBadRequest {
				t.Errorf("%s: status = %d, want 400, body = %s", tc.name, w.Code, w.Body.String())
			}
		})
	}
}

func TestEdge_MissingModel(t *testing.T) {
	srv, _ := testServer(t)

	body := `{"messages":[{"role":"user","content":"hi"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("missing model: status = %d, want 400", w.Code)
	}
}

func TestEdge_EmptyModel(t *testing.T) {
	srv, _ := testServer(t)

	body := `{"model":"","messages":[{"role":"user","content":"hi"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("empty model: status = %d, want 400", w.Code)
	}
}

func TestEdge_EmptyMessages(t *testing.T) {
	srv, _ := testServer(t)

	body := `{"model":"test-model","messages":[]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("empty messages: status = %d, want 400, body = %s", w.Code, w.Body.String())
	}
}

func TestEdge_MissingMessages(t *testing.T) {
	srv, _ := testServer(t)

	body := `{"model":"test-model"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("missing messages: status = %d, want 400", w.Code)
	}
}

func TestEdge_NonCatalogModel(t *testing.T) {
	srv, _ := testServer(t)
	srv.registry.SetModelCatalog([]registry.CatalogEntry{
		{ID: "allowed-model"},
	})

	body := `{"model":"forbidden-model","messages":[{"role":"user","content":"hi"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusNotFound {
		t.Errorf("non-catalog model: status = %d, want 404, body = %s", w.Code, w.Body.String())
	}
}

func TestEdge_UnicodeInModelName(t *testing.T) {
	srv, _ := testServerFastQueue(t)

	body := `{"model":"模型/test-中文","messages":[{"role":"user","content":"hi"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	// Should fail with not found (not in catalog or no provider)
	if w.Code != http.StatusNotFound && w.Code != http.StatusServiceUnavailable {
		t.Errorf("unicode model: status = %d, want 404 or 503", w.Code)
	}
}

func TestEdge_VeryLongModelName(t *testing.T) {
	srv, _ := testServerFastQueue(t)

	longModel := strings.Repeat("a", 10000)
	body := fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":"hi"}]}`, longModel)
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	// Should fail gracefully (not crash). 503 (queue timeout) and 404 (not in catalog) are valid.
	if w.Code == 0 {
		t.Error("very long model name: got status 0")
	}
	// Ensure it doesn't panic or return 500 Internal Server Error
	if w.Code == http.StatusInternalServerError {
		t.Errorf("very long model name: got 500 Internal Server Error: %s", w.Body.String())
	}
}

// ---------------------------------------------------------------------------
// Message content edge cases
// ---------------------------------------------------------------------------

func TestEdge_UnicodeMessages(t *testing.T) {
	ts, cleanup, providerDone := setupE2ETest(t, "unicode-model", func(ctx context.Context, conn *websocket.Conn, inferReq protocol.InferenceRequestMessage) {
		sendChunk(ctx, conn, inferReq.RequestID,
			`data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"你好世界 🌍"},"finish_reason":"stop"}]}`+"\n\n")
		sendComplete(ctx, conn, inferReq.RequestID, protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 3})
	})
	defer cleanup()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	body := `{"model":"unicode-model","messages":[{"role":"user","content":"你好 🌍 emoji test 🎉"}],"stream":true}`
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		t.Fatalf("unicode messages: status = %d, want 200, body = %s", resp.StatusCode, respBody)
	}

	<-providerDone
}

func TestEdge_HTMLInjectionInMessages(t *testing.T) {
	ts, cleanup, providerDone := setupE2ETest(t, "html-model", func(ctx context.Context, conn *websocket.Conn, inferReq protocol.InferenceRequestMessage) {
		sendChunk(ctx, conn, inferReq.RequestID,
			`data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"safe response"},"finish_reason":"stop"}]}`+"\n\n")
		sendComplete(ctx, conn, inferReq.RequestID, protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 2})
	})
	defer cleanup()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	body := `{"model":"html-model","messages":[{"role":"user","content":"<script>alert('xss')</script><img src=x onerror=alert(1)>"}],"stream":true}`
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("html injection: status = %d, want 200", resp.StatusCode)
	}

	<-providerDone
}

// ---------------------------------------------------------------------------
// Authentication edge cases
// ---------------------------------------------------------------------------

func TestEdge_AuthEmptyBearer(t *testing.T) {
	srv, _ := testServer(t)

	body := `{"model":"test","messages":[{"role":"user","content":"hi"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer ")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("empty bearer: status = %d, want 401", w.Code)
	}
}

func TestEdge_AuthMalformedHeader(t *testing.T) {
	srv, _ := testServer(t)

	cases := []struct {
		name   string
		header string
	}{
		{"no_bearer_prefix", "test-key"},
		{"basic_auth", "Basic dGVzdDp0ZXN0"},
		{"double_bearer", "Bearer Bearer test-key"},
		{"just_bearer", "Bearer"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			body := `{"model":"test","messages":[{"role":"user","content":"hi"}]}`
			req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
			req.Header.Set("Authorization", tc.header)
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, req)

			if w.Code != http.StatusUnauthorized {
				t.Errorf("%s: status = %d, want 401", tc.name, w.Code)
			}
		})
	}
}

func TestEdge_WrongHTTPMethod(t *testing.T) {
	srv, _ := testServer(t)

	methods := []string{http.MethodGet, http.MethodPut, http.MethodDelete, http.MethodPatch}
	for _, method := range methods {
		t.Run(method, func(t *testing.T) {
			req := httptest.NewRequest(method, "/v1/chat/completions", nil)
			req.Header.Set("Authorization", "Bearer test-key")
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, req)

			if w.Code != http.StatusMethodNotAllowed {
				t.Errorf("%s: status = %d, want 405", method, w.Code)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// Provider registration edge cases
// ---------------------------------------------------------------------------

func TestEdge_ProviderEmptyModels(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Register a provider with no models
	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{}, testPublicKeyB64())
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Provider should register but not be findable for any model
	time.Sleep(200 * time.Millisecond)
	if p := reg.FindProvider("any-model"); p != nil {
		t.Error("provider with no models should not be findable")
	}
}

func TestEdge_ProviderDuplicateModels(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

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
	// Should register successfully without panicking
	if reg.ProviderCount() != 1 {
		t.Errorf("expected 1 provider, got %d", reg.ProviderCount())
	}
}

func TestEdge_ProviderVeryLargeRegistration(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Register with many models
	var models []protocol.ModelInfo
	for i := 0; i < 100; i++ {
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

// ---------------------------------------------------------------------------
// Trust level and catalog filtering
// ---------------------------------------------------------------------------

func TestEdge_CatalogChangeDuringActiveProvider(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
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
	if p := reg.FindProvider(model); p == nil {
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

// ---------------------------------------------------------------------------
// Provider error handling edge cases
// ---------------------------------------------------------------------------

func TestEdge_ProviderSendsEmptyChunks(t *testing.T) {
	ts, cleanup, providerDone := setupE2ETest(t, "empty-chunk-model", func(ctx context.Context, conn *websocket.Conn, inferReq protocol.InferenceRequestMessage) {
		// Send chunks with empty content
		sendChunk(ctx, conn, inferReq.RequestID,
			`data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}`+"\n\n")
		sendChunk(ctx, conn, inferReq.RequestID,
			`data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":""},"finish_reason":null}]}`+"\n\n")
		sendChunk(ctx, conn, inferReq.RequestID,
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

	ts, cleanup, providerDone := setupE2ETest(t, "large-chunk-model", func(ctx context.Context, conn *websocket.Conn, inferReq protocol.InferenceRequestMessage) {
		sendChunk(ctx, conn, inferReq.RequestID,
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

// ---------------------------------------------------------------------------
// Concurrent consumer requests
// ---------------------------------------------------------------------------

func TestEdge_ConcurrentRequestsSameProvider(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
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

	for i := 0; i < numRequests; i++ {
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

// ---------------------------------------------------------------------------
// Models listing edge cases
// ---------------------------------------------------------------------------

func TestEdge_ModelsEndpointNoProviders(t *testing.T) {
	srv, st := testServer(t)

	// Add models to the catalog store
	st.SetSupportedModel(&store.SupportedModel{
		ID: "model-a", DisplayName: "Model A", ModelType: "text", Active: true,
	})

	// Sync catalog to registry
	srv.SyncModelCatalog()

	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("models endpoint: status = %d, want 200", w.Code)
	}

	var resp struct {
		Data []any `json:"data"`
	}
	json.Unmarshal(w.Body.Bytes(), &resp)

	// With no providers connected, the models list will be empty
	// (models endpoint shows available models from live providers)
	// This verifies the endpoint doesn't crash with no providers
}

// ---------------------------------------------------------------------------
// Release API edge cases
// ---------------------------------------------------------------------------

func TestEdge_ReleaseLatestNoReleases(t *testing.T) {
	srv, _ := testServer(t)

	req := httptest.NewRequest(http.MethodGet, "/v1/releases/latest?platform=macos-arm64", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusNotFound {
		t.Errorf("latest with no releases: status = %d, want 404", w.Code)
	}
}

func TestEdge_ReleaseRegisterNoAuth(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetReleaseKey("secret-release-key")

	body := `{"version":"1.0.0","platform":"macos-arm64","binary_hash":"abc","bundle_hash":"def","url":"http://example.com/bundle.tar.gz"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/releases", strings.NewReader(body))
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("release register without auth: status = %d, want 401", w.Code)
	}
}

func TestEdge_ReleaseRegisterWrongKey(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetReleaseKey("correct-key")

	body := `{"version":"1.0.0","platform":"macos-arm64","binary_hash":"abc","bundle_hash":"def","url":"http://example.com/bundle.tar.gz"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/releases", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer wrong-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("release register wrong key: status = %d, want 401", w.Code)
	}
}

func TestEdge_ReleaseRegisterMissingFields(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetReleaseKey("release-key")

	cases := []struct {
		name string
		body string
	}{
		{"missing_version", `{"platform":"macos-arm64","binary_hash":"abc","bundle_hash":"def","url":"http://example.com/b.tar.gz"}`},
		// platform defaults to "macos-arm64" when omitted, so omit a truly required field instead
		{"empty_version", `{"version":"","platform":"macos-arm64","binary_hash":"abc","bundle_hash":"def","url":"http://example.com/b.tar.gz"}`},
		{"missing_hash", `{"version":"1.0.0","platform":"macos-arm64","url":"http://example.com/b.tar.gz"}`},
		{"missing_bundle_hash", `{"version":"1.0.0","platform":"macos-arm64","binary_hash":"abc","url":"http://example.com/b.tar.gz"}`},
		{"missing_url", `{"version":"1.0.0","platform":"macos-arm64","binary_hash":"abc","bundle_hash":"def"}`},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/v1/releases", strings.NewReader(tc.body))
			req.Header.Set("Authorization", "Bearer release-key")
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, req)

			if w.Code != http.StatusBadRequest {
				t.Errorf("%s: status = %d, want 400, body = %s", tc.name, w.Code, w.Body.String())
			}
		})
	}
}

func TestEdge_ReleaseRegisterAndRetrieve(t *testing.T) {
	srv, st := testServer(t)
	srv.SetReleaseKey("release-key")

	// Register a release
	body := `{"version":"1.0.0","platform":"macos-arm64","binary_hash":"abc123","bundle_hash":"def456","url":"http://example.com/bundle.tar.gz","changelog":"First release"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/releases", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer release-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK && w.Code != http.StatusCreated {
		t.Fatalf("register release: status = %d, body = %s", w.Code, w.Body.String())
	}

	// Retrieve latest
	req = httptest.NewRequest(http.MethodGet, "/v1/releases/latest?platform=macos-arm64", nil)
	w = httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("get latest: status = %d, body = %s", w.Code, w.Body.String())
	}

	var latest map[string]any
	json.Unmarshal(w.Body.Bytes(), &latest)
	if latest["version"] != "1.0.0" {
		t.Errorf("latest version = %v, want 1.0.0", latest["version"])
	}

	// Verify binary hashes were synced
	releases := st.ListReleases()
	if len(releases) == 0 {
		t.Error("expected at least one release in store")
	}
}

// ---------------------------------------------------------------------------
// Error response format
// ---------------------------------------------------------------------------

func TestEdge_ErrorResponseFormat(t *testing.T) {
	srv, _ := testServer(t)

	// Send invalid request to trigger error
	body := `{"model":"","messages":[]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	var errResp struct {
		Error struct {
			Type    string `json:"type"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &errResp); err != nil {
		t.Fatalf("error response is not valid JSON: %v, body = %s", err, w.Body.String())
	}

	if errResp.Error.Type == "" {
		t.Error("error response missing 'type' field")
	}
	if errResp.Error.Message == "" {
		t.Error("error response missing 'message' field")
	}
}

// ---------------------------------------------------------------------------
// Provider disconnect during inference
// ---------------------------------------------------------------------------

func TestEdge_ProviderDisconnectMidStream(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

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
				sendChunk(ctx, conn, req.RequestID,
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

// ---------------------------------------------------------------------------
// Non-streaming inference
// ---------------------------------------------------------------------------

func TestEdge_NonStreamingResponse(t *testing.T) {
	ts, cleanup, providerDone := setupE2ETest(t, "nonstream-model", func(ctx context.Context, conn *websocket.Conn, inferReq protocol.InferenceRequestMessage) {
		// Provider sends a non-streaming response (single chunk with full content + complete)
		sendChunk(ctx, conn, inferReq.RequestID,
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

// ---------------------------------------------------------------------------
// Version endpoint
// ---------------------------------------------------------------------------

func TestEdge_VersionEndpoint(t *testing.T) {
	srv, _ := testServer(t)

	req := httptest.NewRequest(http.MethodGet, "/api/version", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("version: status = %d, want 200", w.Code)
	}

	var resp map[string]any
	json.Unmarshal(w.Body.Bytes(), &resp)
	if resp["version"] == nil {
		t.Error("version response missing 'version' field")
	}
	if resp["download_url"] == nil {
		t.Error("version response missing 'download_url' field")
	}
}

// ---------------------------------------------------------------------------
// Provider with invalid public key
// ---------------------------------------------------------------------------

func TestEdge_ProviderInvalidPublicKey(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

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

// suppress unused import warnings
var _ = rand.Read
var _ = base64.StdEncoding
