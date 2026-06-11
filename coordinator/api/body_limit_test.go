package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// overChatBody returns a reader whose total length exceeds maxInferenceBodyBytes.
// The extra bytes are in the content field so the body is syntactically valid
// up to the cap and the limit fires inside io.ReadAll.
func overChatBody() *strings.Reader {
	// Pad past the 64 MiB cap so the limit fires inside io.ReadAll.
	pad := strings.Repeat("x", 65<<20)
	return strings.NewReader(`{"model":"m","messages":[{"role":"user","content":"` + pad + `"}]}`)
}

func overCompletionsBody() *strings.Reader {
	pad := strings.Repeat("x", 65<<20)
	return strings.NewReader(`{"model":"m","prompt":"` + pad + `"}`)
}

// TestChatCompletionsBodyTooLarge verifies that POST /v1/chat/completions with a
// body exceeding maxInferenceBodyBytes returns HTTP 413.
func TestChatCompletionsBodyTooLarge(t *testing.T) {
	srv, _ := testServer(t)
	// Seed a catalog so a cap regression fails fast (404 unknown model) rather
	// than blocking in the provider queue for the full timeout.
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: "known-model"}})

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", overChatBody())
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("chat/completions oversized body: want 413, got %d", w.Code)
	}
}

// TestCompletionsBodyTooLarge verifies that POST /v1/completions with a body
// exceeding maxInferenceBodyBytes returns HTTP 413.
func TestCompletionsBodyTooLarge(t *testing.T) {
	srv, _ := testServer(t)
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: "known-model"}})

	req := httptest.NewRequest(http.MethodPost, "/v1/completions", overCompletionsBody())
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("completions oversized body: want 413, got %d", w.Code)
	}
}

// TestChatCompletionsSmallBodyNotRejected confirms that a small, well-formed
// body is not rejected with 413. A catalog is set so the unknown model returns
// 404 immediately rather than blocking in the provider queue.
func TestChatCompletionsSmallBodyNotRejected(t *testing.T) {
	srv, _ := testServer(t)
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: "known-model"}})

	body := `{"model":"unknown-model","messages":[{"role":"user","content":"hi"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code == http.StatusRequestEntityTooLarge {
		t.Errorf("chat/completions small body: got unexpected 413")
	}
}

// TestCompletionsSmallBodyNotRejected confirms that a small body to /v1/completions
// is not rejected with 413. A catalog is set so the unknown model returns 404
// immediately rather than blocking in the provider queue.
func TestCompletionsSmallBodyNotRejected(t *testing.T) {
	srv, _ := testServer(t)
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: "known-model"}})

	body := `{"model":"unknown-model","prompt":"hello"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code == http.StatusRequestEntityTooLarge {
		t.Errorf("completions small body: got unexpected 413")
	}
}
