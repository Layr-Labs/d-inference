package api_test

import (
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	middleware "github.com/eigeninference/d-inference/coordinator/internal/api/middleware"
)

// infiniteReader yields 'a' forever; with io.LimitReader it streams an
// over-cap body without allocating it, so the cap surfaces as a read error.
type infiniteReader struct{}

const testMaxRequestBodyBytes = 64 << 20

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
	s := middleware.New(nil, nil, nil, "")
	var readErr error
	h := s.BodyLimit(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, readErr = io.Copy(io.Discard, r.Body)
	}))
	req := httptest.NewRequest(http.MethodPost, "/v1/enroll",
		io.LimitReader(infiniteReader{}, int64(testMaxRequestBodyBytes)+1))
	h.ServeHTTP(httptest.NewRecorder(), req)

	var maxErr *http.MaxBytesError
	if !errors.As(readErr, &maxErr) {
		t.Fatalf("expected the body to be capped (*http.MaxBytesError), got %v", readErr)
	}
}

// The provider WebSocket upgrade is exempt — it hijacks the connection and
// reads framed messages, not r.Body — so the global cap must not apply.
func TestBodyLimitMiddlewareExemptsProviderWS(t *testing.T) {
	s := middleware.New(nil, nil, nil, "")
	var readErr error
	h := s.BodyLimit(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, readErr = io.Copy(io.Discard, r.Body)
	}))
	req := httptest.NewRequest(http.MethodGet, "/ws/provider",
		io.LimitReader(infiniteReader{}, int64(testMaxRequestBodyBytes)+1))
	h.ServeHTTP(httptest.NewRecorder(), req)

	if readErr != nil {
		t.Fatalf("/ws/provider must be exempt from the body cap, got read error: %v", readErr)
	}
}
