package inference_test

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	api "github.com/eigeninference/d-inference/coordinator/api"
	testkit "github.com/eigeninference/d-inference/coordinator/api/tests/internal/testkit"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestSecurity_OversizedRequestBody(t *testing.T) {
	fixture := testkit.New(t, api.ServerConfig{})
	srv := fixture.Server

	// Pre-fill queue for "test" model so the request returns 503 immediately
	// instead of blocking for 30s waiting for a provider.
	for i := range 10 {
		_ = fixture.Registry.Queue().Enqueue(&registry.QueuedRequest{
			RequestID:  fmt.Sprintf("oversized-filler-%d", i),
			Model:      "test",
			ResponseCh: make(chan *registry.Provider, 1),
		})
	}

	// Build a 10MB request body.
	bigContent := strings.Repeat("A", 10*1024*1024)
	body := fmt.Sprintf(`{"model":"test","messages":[{"role":"user","content":"%s"}]}`, bigContent)

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()

	srv.Handler().ServeHTTP(w, req)

	// Server should either:
	// - Return 413 (body too large)
	// - Return 503 (no provider available — meaning it parsed but found no provider)
	// - Return some other error
	// It should NOT panic or OOM.
	if w.Code == 0 {
		t.Error("expected a response, got nothing")
	}
	t.Logf("10MB request body returned status %d (server did not crash)", w.Code)

	// Verify server still works after the oversized request.
	healthReq := httptest.NewRequest(http.MethodGet, "/health", nil)
	healthW := httptest.NewRecorder()
	srv.Handler().ServeHTTP(healthW, healthReq)
	if healthW.Code != http.StatusOK {
		t.Errorf("health check after oversized request: status %d, want 200", healthW.Code)
	}
}

func TestSecurity_HeaderInjection(t *testing.T) {
	fixture := testkit.New(t, api.ServerConfig{})
	srv := fixture.Server

	t.Run("model_with_newlines", func(t *testing.T) {
		// Model name containing newlines should not inject HTTP headers.
		// Pre-fill queue so it returns 503 immediately instead of blocking 30s.
		injectedModel := "test\r\nX-Injected: true\r\n"
		for i := range 10 {
			_ = fixture.Registry.Queue().Enqueue(&registry.QueuedRequest{
				RequestID:  fmt.Sprintf("header-inj-filler-%d", i),
				Model:      injectedModel,
				ResponseCh: make(chan *registry.Provider, 1),
			})
		}

		body := fmt.Sprintf(`{"model":"%s","messages":[{"role":"user","content":"hi"}]}`, `test\r\nX-Injected: true\r\n`)
		req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer test-key")
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)

		// The response should NOT contain the injected header.
		if w.Header().Get("X-Injected") == "true" {
			t.Error("header injection succeeded — model name newlines were reflected in response headers")
		}

		// Server should return a normal response (likely 503 no provider), not crash.
		if w.Code == 0 {
			t.Error("expected a response, got nothing")
		}
	})

	t.Run("content_with_control_chars", func(t *testing.T) {
		// Content containing control characters should be handled safely.
		body := `{"model":"test","messages":[{"role":"user","content":"hello\x00\x01\x02\x03"}]}`
		req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer test-key")
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)

		// Should not crash. Any status is fine as long as it's a valid HTTP response.
		if w.Code == 0 {
			t.Error("expected a response, got nothing")
		}
		t.Logf("control chars in content: status %d", w.Code)
	})

	t.Run("auth_header_with_newlines", func(t *testing.T) {
		body := `{"model":"test","messages":[{"role":"user","content":"hi"}]}`
		req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
		// Try to inject a header via the Authorization value.
		req.Header.Set("Authorization", "Bearer fake\r\nX-Injected: true")
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)

		if w.Header().Get("X-Injected") == "true" {
			t.Error("header injection via Authorization succeeded")
		}

		// Should be rejected (401 since the token is invalid).
		if w.Code != http.StatusUnauthorized {
			t.Logf("auth header with newlines: status %d (expected 401)", w.Code)
		}
	})
}
