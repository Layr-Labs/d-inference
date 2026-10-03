package api

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/google/uuid"
)

// Accounting identity is independent without changing the public correlation header.
func TestRequestOutcomeInferenceIdentityPreservesHeader(t *testing.T) {
	t.Setenv(envProfiler, "off")
	srv := &Server{logger: quietLogger()}
	seen := make(map[string]bool)
	for _, endpoint := range []string{"/v1/chat/completions", "/v1/responses", "/v1/completions", "/v1/messages"} {
		for _, supplied := range []string{"", "client-id"} {
			var canonical, logged string
			h := srv.loggingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				canonical = observation.CoordRequestIDFromContext(r.Context())
				logged = access.RequestIDFromContext(r.Context())
				w.WriteHeader(http.StatusNoContent)
			}))
			req := httptest.NewRequest(http.MethodPost, endpoint, nil)
			req.Header.Set("X-Request-ID", supplied)
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			public := rec.Header().Get("X-Request-ID")
			if public != logged || (supplied != "" && public != supplied) || (supplied == "" && len(public) != 12) {
				t.Fatalf("public correlation changed: supplied=%q header=%q log=%q", supplied, public, logged)
			}
			if _, err := uuid.Parse(canonical); err != nil || canonical == public || seen[canonical] {
				t.Fatalf("canonical identity not independent: %q, %v", canonical, err)
			}
			seen[canonical] = true
		}
	}
}
