package inference_test

import (
	"log/slog"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// setupTTFTFailoverServer mirrors setupFailoverServer but returns the *Server
// so the test can flip the hard TTFT gate (the failover harness hides it).
func setupTTFTFailoverServer(t *testing.T) (*registry.Registry, *memory.MemoryStore, *serverFixture, *httptest.Server) {
	return setupTTFTFailoverServerWithConfig(t, TestServerConfig{})
}

func setupTTFTFailoverServerWithConfig(
	t *testing.T,
	cfg TestServerConfig,
) (*registry.Registry, *memory.MemoryStore, *serverFixture, *httptest.Server) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	// These fixtures exercise the opted-in SLA path. Explicit empty selects exemption.
	if cfg.FirstContentSLAAccounts == nil {
		cfg.FirstContentSLAAccounts = []string{testConsumerID}
	}
	srv := newComposedServer(reg, st, cfg, logger)
	srv.server.SetChallengeInterval(500 * time.Millisecond)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return reg, st, srv, ts
}

// makeProviderTTFTSlow stamps BackendCapacity (required for the scheduler's
// TTFT ceiling: providers without it are never TTFT-enforced) and a crawling
// prefill rate on a harness provider, so its estimated TTFT lands far above
// the ~5s prompt-scaled deadline and ReserveProviderEx TTFT-rejects it.
func makeProviderTTFTSlow(t *testing.T, reg *registry.Registry, registryID, model string) {
	t.Helper()
	p := reg.GetProvider(registryID)
	if p == nil {
		t.Fatalf("provider %q missing", registryID)
	}
	p.Mu().Lock()
	p.PrefillTPS = 0.2 // a handful of prompt tokens => ~25s+ estimated prefill
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{{
			Model: model, State: "running", MaxConcurrency: 8, ActiveTokenBudgetMax: 200_000,
		}},
	}
	p.Mu().Unlock()
	reportMeasuredFirstContentEvidence(t, reg, registryID, model, 0.2, 100)
}
