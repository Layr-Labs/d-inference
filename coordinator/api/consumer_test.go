package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

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

	origin := w.Header().Get("Access-Control-Allow-Origin")
	if origin == "*" {
		t.Errorf("CORS origin must not be wildcard, got %q", origin)
	}
	if origin == "" {
		t.Errorf("CORS origin header missing")
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

// TestCORSPublicEndpointsAllowAnyOrigin verifies the public, non-credentialed
// read endpoints (consumed by the marketing site) are readable cross-origin via
// a wildcard, while credentialed endpoints stay locked to a single origin.
func TestCORSPublicEndpointsAllowAnyOrigin(t *testing.T) {
	srv, _ := testServer(t)

	for _, path := range []string{"/v1/models/catalog", "/v1/pricing"} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)
		if got := w.Header().Get("Access-Control-Allow-Origin"); got != "*" {
			t.Errorf("%s: Access-Control-Allow-Origin = %q, want \"*\"", path, got)
		}
		// A wildcard origin must never be paired with credentials.
		if got := w.Header().Get("Access-Control-Allow-Credentials"); got != "" {
			t.Errorf("%s: Access-Control-Allow-Credentials = %q, want empty", path, got)
		}
	}

	// A non-public endpoint keeps the locked single origin (never wildcard).
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)
	if got := w.Header().Get("Access-Control-Allow-Origin"); got == "*" || got == "" {
		t.Errorf("/health: Access-Control-Allow-Origin = %q, want a specific origin", got)
	}

	// /v1/pricing also serves authenticated PUT/DELETE. A preflight for a
	// non-GET method must keep the credentialed, single-origin CORS (not the
	// wildcard public GET headers) so the mutation's preflight is accepted.
	preflight := httptest.NewRequest(http.MethodOptions, "/v1/pricing", nil)
	preflight.Header.Set("Access-Control-Request-Method", http.MethodDelete)
	pw := httptest.NewRecorder()
	srv.Handler().ServeHTTP(pw, preflight)
	if got := pw.Header().Get("Access-Control-Allow-Origin"); got == "*" || got == "" {
		t.Errorf("DELETE /v1/pricing preflight: Allow-Origin = %q, want the configured origin (not wildcard)", got)
	}
	if got := pw.Header().Get("Access-Control-Allow-Credentials"); got != "true" {
		t.Errorf("DELETE /v1/pricing preflight: Allow-Credentials = %q, want \"true\"", got)
	}
	if got := pw.Header().Get("Access-Control-Allow-Methods"); got != "GET, POST, PUT, DELETE, OPTIONS" {
		t.Errorf("DELETE /v1/pricing preflight: Allow-Methods = %q, want the credentialed method set", got)
	}
}
