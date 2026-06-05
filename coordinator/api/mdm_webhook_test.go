package api

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func mdmTestServer(t *testing.T) *Server {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	return NewServer(reg, st, ServerConfig{}, logger)
}

// TestMDMWebhookSecretGate verifies the optional shared-secret layer: when a
// secret is configured, callers without it are rejected before the body is read;
// with it, the request is accepted.
func TestMDMWebhookSecretGate(t *testing.T) {
	srv := mdmTestServer(t)
	srv.SetMDMWebhookSecret("s3cret")

	// No token → forbidden.
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/mdm/webhook", strings.NewReader("{}"))
	srv.HandleMDMWebhook(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("missing token: want 403, got %d", rec.Code)
	}

	// Wrong token → forbidden.
	rec = httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodPost, "/v1/mdm/webhook?token=wrong", strings.NewReader("{}"))
	srv.HandleMDMWebhook(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("wrong token: want 403, got %d", rec.Code)
	}

	// Correct token (query param) → accepted (200; body is empty JSON, no-op).
	rec = httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodPost, "/v1/mdm/webhook?token=s3cret", strings.NewReader("{}"))
	srv.HandleMDMWebhook(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("correct token (query): want 200, got %d", rec.Code)
	}

	// Correct token (header) → accepted.
	rec = httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodPost, "/v1/mdm/webhook", strings.NewReader("{}"))
	req.Header.Set("X-Webhook-Token", "s3cret")
	srv.HandleMDMWebhook(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("correct token (header): want 200, got %d", rec.Code)
	}
}

// TestMDMWebhookNoSecretConfigured verifies that when no secret is set, the
// endpoint does not 403 (it relies on the solicited-command gate instead).
func TestMDMWebhookNoSecretConfigured(t *testing.T) {
	srv := mdmTestServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/mdm/webhook", strings.NewReader("{}"))
	srv.HandleMDMWebhook(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("no secret configured: want 200, got %d", rec.Code)
	}
}
