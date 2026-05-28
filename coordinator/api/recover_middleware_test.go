package api

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/telemetry"
)

func TestRecoverMiddlewareCatchesPanic(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetAdminKey("admin-key")

	// Emitter wired for metric side-effects (Datadog forwarding is no-op in tests).
	srv.SetEmitter(telemetry.NewEmitter(srv.logger, srv.metrics, "test"))

	// Mount a panicking handler onto the internal mux directly.
	srv.mux.HandleFunc("GET /v1/test/boom", func(w http.ResponseWriter, r *http.Request) {
		panic("intentional test panic")
	})

	req := httptest.NewRequest(http.MethodGet, "/v1/test/boom", nil)
	rr := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusInternalServerError {
		t.Fatalf("status: got %d want 500", rr.Code)
	}

}
