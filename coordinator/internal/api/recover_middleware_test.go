package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/coordinator/internal/store"
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

	events, err := st.ListTelemetryEvents(context.Background(), store.TelemetryFilter{Kind: "panic", Limit: 10})
	if err != nil {
		t.Fatalf("list events: %v", err)
	}
	if len(events) == 0 {
		t.Fatalf("no panic telemetry stored")
	}
	if events[0].Stack == "" {
		t.Fatalf("stack missing on panic event")
	}
}
