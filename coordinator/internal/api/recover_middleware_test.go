package api

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/coordinator/internal/telemetry"
)

func TestRecoverMiddlewareCatchesPanic(t *testing.T) {
	srv, st := testServer(t)
	srv.SetAdminKey("admin-key")

	// Emitter wired so we can confirm the event lands in the store.
	srv.SetEmitter(telemetry.NewEmitter(srv.logger, st, srv.metrics, "test"))

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

	events := st.TelemetryEventsSnapshot()
	found := false
	for _, e := range events {
		if e.Kind == "panic" {
			found = true
			if e.Stack == "" {
				t.Fatalf("stack missing on panic event")
			}
			break
		}
	}
	if !found {
		t.Fatalf("no panic telemetry stored")
	}
}
