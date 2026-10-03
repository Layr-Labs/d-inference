package inference_test

import (
	"io"
	"log/slog"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/tests/internal/testkit"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

var testConsumerID = store.LegacyAccountID("test-key")

const envProfiler = "EIGENINFERENCE_PROFILER"

func quietLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func setupTestServer(t *testing.T) (*api.Server, *registry.Registry, store.Store, *httptest.Server) {
	t.Helper()
	fixture := testkit.New(t, api.ServerConfig{})
	fixture.Server.SetChallengeInterval(200 * time.Millisecond)
	ts := httptest.NewServer(fixture.Server.Handler())
	t.Cleanup(ts.Close)
	return fixture.Server, fixture.Registry, fixture.Store, ts
}
