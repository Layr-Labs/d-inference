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
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

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

	// Should fail with not found (not in catalog), 429 (queue timeout), or 503 (no provider).
	if w.Code != http.StatusNotFound && w.Code != http.StatusTooManyRequests && w.Code != http.StatusServiceUnavailable {
		t.Errorf("unicode model: status = %d, want 404, 429, or 503", w.Code)
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

func TestEdge_UnicodeMessages(t *testing.T) {
	ts, cleanup, providerDone := setupE2ETest(t, "unicode-model", func(ctx context.Context, conn *websocket.Conn, inferReq protocol.InferenceRequestMessage, providerPublicKey string) {
		sendChunk(t, ctx, conn, inferReq, providerPublicKey,
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
	ts, cleanup, providerDone := setupE2ETest(t, "html-model", func(ctx context.Context, conn *websocket.Conn, inferReq protocol.InferenceRequestMessage, providerPublicKey string) {
		sendChunk(t, ctx, conn, inferReq, providerPublicKey,
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

	// /v1/chat/completions is POST-only. Wrong methods are caught by the
	// /v1/ catch-all and return a structured JSON 404 (not Go's default 405
	// text/plain), which is better for OpenAI SDK compatibility.
	methods := []string{http.MethodGet, http.MethodPut, http.MethodDelete, http.MethodPatch}
	for _, method := range methods {
		t.Run(method, func(t *testing.T) {
			req := httptest.NewRequest(method, "/v1/chat/completions", nil)
			req.Header.Set("Authorization", "Bearer test-key")
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, req)

			if w.Code != http.StatusNotFound {
				t.Errorf("%s: status = %d, want 404", method, w.Code)
			}
			ct := w.Header().Get("Content-Type")
			if ct != "application/json" {
				t.Errorf("%s: Content-Type = %q, want application/json", method, ct)
			}
		})
	}
}

func TestEdge_ErrorResponseFormat(t *testing.T) {
	srv, _ := testServer(t)

	// Send invalid request to trigger error (empty model triggers "model is required")
	body := `{"model":"","messages":[]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	var errResp struct {
		Error struct {
			Type    string `json:"type"`
			Message string `json:"message"`
			Code    string `json:"code"`
			Param   string `json:"param"`
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
	if errResp.Error.Code == "" {
		t.Error("error response missing 'code' field — required by OpenAI spec for SDK error handling")
	}
	if errResp.Error.Param != "model" {
		t.Errorf("error response param = %q, want %q", errResp.Error.Param, "model")
	}
}

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

func TestEdge_VersionEndpointIncludesSwiftReleaseMetadata(t *testing.T) {
	srv, st := testServer(t)
	binaryHash := strings.Repeat("a", 64)
	bundleHash := strings.Repeat("b", 64)
	metallibHash := strings.Repeat("c", 64)
	if err := st.SetRelease(&store.Release{
		Version:      "1.2.3",
		Platform:     "macos-arm64",
		Backend:      "mlx-swift",
		BinaryHash:   binaryHash,
		BundleHash:   bundleHash,
		MetallibHash: metallibHash,
		URL:          "https://example.com/darkbloom.tar.gz",
		Changelog:    "Swift bridge",
	}); err != nil {
		t.Fatalf("SetRelease: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/api/version", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("version: status = %d, want 200", w.Code)
	}

	var resp map[string]string
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp["backend"] != "mlx-swift" {
		t.Fatalf("backend = %q, want mlx-swift", resp["backend"])
	}
	if resp["binary_hash"] != binaryHash {
		t.Fatalf("binary_hash = %q, want %q", resp["binary_hash"], binaryHash)
	}
	if resp["bundle_hash"] != bundleHash {
		t.Fatalf("bundle_hash = %q, want %q", resp["bundle_hash"], bundleHash)
	}
	if resp["metallib_hash"] != metallibHash {
		t.Fatalf("metallib_hash = %q, want %q", resp["metallib_hash"], metallibHash)
	}
}
