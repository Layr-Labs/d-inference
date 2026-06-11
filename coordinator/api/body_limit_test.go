package api

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// xReader yields an endless stream of 'x' without a backing buffer, so the
// oversized-body tests can exceed the 64 MiB cap without materializing a
// ~65 MiB string in memory.
type xReader struct{}

func (xReader) Read(p []byte) (int, error) {
	for i := range p {
		p[i] = 'x'
	}
	return len(p), nil
}

// oversizedJSONBody streams a syntactically-plausible JSON body whose total size
// exceeds maxInferenceBodyBytes — prefix + >64 MiB of 'x' + suffix — without
// buffering it. The handler's MaxBytesReader trips mid-read, before the body is
// fully consumed. Shared by the chat and completions oversized cases.
func oversizedJSONBody(prefix, suffix string) io.Reader {
	const pad = 65 << 20 // > the 64 MiB cap
	return io.MultiReader(
		strings.NewReader(prefix),
		io.LimitReader(xReader{}, pad),
		strings.NewReader(suffix),
	)
}

func overChatBody() io.Reader {
	return oversizedJSONBody(`{"model":"m","messages":[{"role":"user","content":"`, `"}]}`)
}

func overCompletionsBody() io.Reader {
	return oversizedJSONBody(`{"model":"m","prompt":"`, `"}`)
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
