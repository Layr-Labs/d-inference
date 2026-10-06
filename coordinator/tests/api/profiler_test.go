package api_test

import (
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/api/readcache"

	middleware "github.com/eigeninference/d-inference/coordinator/internal/api/middleware"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func newProfilerTestServer(t *testing.T) *middleware.Stack {
	t.Helper()
	t.Setenv("EIGENINFERENCE_PROFILE_SAMPLE_RATE", "1")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{})
	runtime := production.NewRuntime(production.RuntimeDependencies{
		Registry: registry.New(logger), Store: st, Ledger: payments.NewLedger(st), ReadCache: readcache.New(), Logger: logger,
	}, production.ServerConfig{AdminKey: "admin-test-key"})
	t.Cleanup(runtime.Server.Close)
	return middleware.New(logger, runtime.Observation, runtime.Server.Inference(), "")
}

func TestRequestMetaAlwaysMintsCoordinatorID(t *testing.T) {
	srv := newProfilerTestServer(t)
	var seenCoord, seenReq string
	h := srv.Logging(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenCoord = observation.CoordRequestIDFromContext(r.Context())
		seenReq = access.RequestIDFromContext(r.Context())
		w.WriteHeader(http.StatusNoContent)
	}))
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	req.Header.Set("X-Request-ID", "=client-controlled@id")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if seenReq != "=client-controlled@id" {
		t.Fatal("client id must still be honoured for logs/header")
	}
	if seenCoord == "" || seenCoord == seenReq {
		t.Fatalf("coordinator id must be minted independently, got %q", seenCoord)
	}
	req2 := httptest.NewRequest(http.MethodGet, "/health", nil)
	h.ServeHTTP(httptest.NewRecorder(), req2)
	if seenCoord != seenReq {
		t.Fatal("without a client id, the minted id serves both roles")
	}
}

func TestProfilerKillSwitchDoesNotAttachRequestMetadata(t *testing.T) {
	t.Setenv("EIGENINFERENCE_PROFILER", "off")
	srv := newProfilerTestServer(t)
	h := srv.Logging(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if observation.HasRequestMeta(r.Context()) {
			t.Error("no request meta when the profiler is off")
		}
	}))
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/health", nil))
}
