package access_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/tests/internal/testkit"
)

func TestCORSHeaders(t *testing.T) {
	fixture := testkit.New(t, api.ServerConfig{})
	srv := fixture.Server

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
	fixture := testkit.New(t, api.ServerConfig{})
	srv := fixture.Server

	req := httptest.NewRequest(http.MethodOptions, "/v1/chat/completions", nil)
	req.Header.Set("Access-Control-Request-Headers", "authorization, "+"X-Darkbloom-Metadata-Details")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusNoContent {
		t.Errorf("status = %d, want %d", w.Code, http.StatusNoContent)
	}
	if got := w.Header().Get("Access-Control-Allow-Headers"); !strings.Contains(strings.ToLower(got), strings.ToLower("X-Darkbloom-Metadata-Details")) {
		t.Errorf("Access-Control-Allow-Headers = %q, want %q", got, "X-Darkbloom-Metadata-Details")
	}
}

func TestCORSPublicEndpointsAllowAnyOrigin(t *testing.T) {
	fixture := testkit.New(t, api.ServerConfig{})
	srv := fixture.Server

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
