package api

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// /metrics must serve a Prometheus exposition payload that includes our
// custom metric names. CounterVec series only appear in the exposition
// after WithLabelValues has been called at least once (no zero-init), so
// fire one synthetic request through the middleware first.
func TestMetricsEndpointServes(t *testing.T) {
	s := newTestServerForObservability()

	// Drive one request through the chain so HTTPRequests has a series.
	probe := httptest.NewRecorder()
	probeReq := httptest.NewRequest("GET", "/metrics", nil)
	s.Handler().ServeHTTP(probe, probeReq)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/metrics", nil)
	s.mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("/metrics status = %d, want 200", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "eigeninference_http_requests_total") {
		t.Errorf("/metrics body missing eigeninference_http_requests_total\nbody (first 1000 chars):\n%s", body[:min(1000, len(body))])
	}
	if !strings.Contains(body, "eigeninference_http_request_duration_seconds") {
		t.Errorf("/metrics body missing eigeninference_http_request_duration_seconds")
	}
}

// loggingMiddleware must generate an X-Request-ID and surface it on the
// response so clients can quote it back to support.
func TestRequestIDHeaderEcho(t *testing.T) {
	s := newTestServerForObservability()
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/metrics", nil)
	s.Handler().ServeHTTP(rec, req) // go through middleware chain
	if id := rec.Header().Get("X-Request-ID"); id == "" {
		t.Fatal("X-Request-ID header not set on response")
	}
}

// Inbound X-Request-ID is honored when present so a caller's tracing
// system can correlate.
func TestRequestIDHonorsInbound(t *testing.T) {
	s := newTestServerForObservability()
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/metrics", nil)
	req.Header.Set("X-Request-ID", "trace-abc-123")
	s.Handler().ServeHTTP(rec, req)
	if got := rec.Header().Get("X-Request-ID"); got != "trace-abc-123" {
		t.Errorf("X-Request-ID = %q, want trace-abc-123", got)
	}
}

func newTestServerForObservability() *Server {
	// Use the package-internal mux directly so we don't need a store etc.
	// /metrics is independent of registry/store; only the logging
	// middleware needs a logger to avoid a nil deref.
	s := &Server{
		mux:    http.NewServeMux(),
		logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
	s.routes() // routes() only registers handlers; nothing fires until requests come in.
	return s
}
