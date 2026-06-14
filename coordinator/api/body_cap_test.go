package api

import (
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// infiniteReader yields 'a' forever; with io.LimitReader it streams an
// over-cap body without allocating it, so the cap surfaces as a read error.
type infiniteReader struct{}

func (infiniteReader) Read(p []byte) (int, error) {
	for i := range p {
		p[i] = 'a'
	}
	return len(p), nil
}

// The global middleware caps an oversized body on a normal route, so an
// unbounded POST can't OOM the coordinator. io.Copy(io.Discard, …) drains
// without buffering, so the cap shows up as a *http.MaxBytesError.
func TestBodyLimitMiddlewareCapsOversizedBody(t *testing.T) {
	s := &Server{}
	var readErr error
	h := s.bodyLimitMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, readErr = io.Copy(io.Discard, r.Body)
	}))
	req := httptest.NewRequest(http.MethodPost, "/v1/enroll",
		io.LimitReader(infiniteReader{}, int64(maxRequestBodyBytes)+1))
	h.ServeHTTP(httptest.NewRecorder(), req)

	var maxErr *http.MaxBytesError
	if !errors.As(readErr, &maxErr) {
		t.Fatalf("expected the body to be capped (*http.MaxBytesError), got %v", readErr)
	}
}

// The provider WebSocket upgrade is exempt — it hijacks the connection and
// reads framed messages, not r.Body — so the global cap must not apply.
func TestBodyLimitMiddlewareExemptsProviderWS(t *testing.T) {
	s := &Server{}
	var readErr error
	h := s.bodyLimitMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, readErr = io.Copy(io.Discard, r.Body)
	}))
	req := httptest.NewRequest(http.MethodGet, "/ws/provider",
		io.LimitReader(infiniteReader{}, int64(maxRequestBodyBytes)+1))
	h.ServeHTTP(httptest.NewRecorder(), req)

	if readErr != nil {
		t.Fatalf("/ws/provider must be exempt from the body cap, got read error: %v", readErr)
	}
}

// decodeCappedJSON: over-cap (but valid-JSON-shaped) -> 413; small invalid JSON
// -> 400; valid -> ok with the value decoded.
func TestDecodeCappedJSON(t *testing.T) {
	type payload struct {
		X string `json:"x"`
	}

	t.Run("oversized->413", func(t *testing.T) {
		// Valid JSON shape that runs past the cap mid-string, so the decoder
		// hits the MaxBytesReader limit rather than a JSON syntax error.
		big := `{"x":"` + strings.Repeat("a", maxControlPlaneBodyBytes) + `"}`
		w := httptest.NewRecorder()
		r := httptest.NewRequest(http.MethodPost, "/x", strings.NewReader(big))
		var dst payload
		if decodeCappedJSON(w, r, maxControlPlaneBodyBytes, &dst) {
			t.Fatal("expected ok=false for an over-cap body")
		}
		if w.Code != http.StatusRequestEntityTooLarge {
			t.Fatalf("oversized: got %d, want 413", w.Code)
		}
	})

	t.Run("invalidJSON->400", func(t *testing.T) {
		w := httptest.NewRecorder()
		r := httptest.NewRequest(http.MethodPost, "/x", strings.NewReader("not json"))
		var dst payload
		if decodeCappedJSON(w, r, maxControlPlaneBodyBytes, &dst) {
			t.Fatal("expected ok=false for invalid JSON")
		}
		if w.Code != http.StatusBadRequest {
			t.Fatalf("invalid JSON: got %d, want 400", w.Code)
		}
	})

	t.Run("valid->ok", func(t *testing.T) {
		w := httptest.NewRecorder()
		r := httptest.NewRequest(http.MethodPost, "/x", strings.NewReader(`{"x":"hi"}`))
		var dst payload
		if !decodeCappedJSON(w, r, maxControlPlaneBodyBytes, &dst) {
			t.Fatalf("expected ok=true for valid JSON (status %d)", w.Code)
		}
		if dst.X != "hi" {
			t.Fatalf("decoded X=%q, want %q", dst.X, "hi")
		}
	})
}
