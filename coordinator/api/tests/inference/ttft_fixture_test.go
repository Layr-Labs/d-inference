package inference_test

// Terminal TTFT-rejection regression tests.
//
// A reservation that fails because every candidate exceeds the TTFT ceiling
// (errTTFTTooSlow, EIGENINFERENCE_TTFT_HARD_REJECT=true) is deterministic: the
// scheduler computes it from the same fleet-wide estimate on every scan, so
// re-running it within the same request cannot succeed. Pre-fix, only attempt 0
// failed fast; a MID-LADDER rejection (after an earlier provider error caused a
// failover) fell into the generic retry path and re-ran the doomed scan up to
// maxDispatchAttempts — in prod ~62.7 ttft_429 inference_routes rows per
// rejected request (28% of the table), the whole futile ladder completing in
// ~30ms. The fix terminates the ladder on the FIRST TTFT rejection at ANY
// attempt, gated by EIGENINFERENCE_TTFT_TERMINAL_REJECT (default true).

import (
	"log/slog"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	api "github.com/eigeninference/d-inference/coordinator/api"
	testkit "github.com/eigeninference/d-inference/coordinator/api/tests/internal/testkit"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// setupTTFTFailoverServer mirrors setupFailoverServer but returns the *Server
// so the test can flip the hard TTFT gate (the failover harness hides it).
func setupTTFTFailoverServer(t *testing.T) (*registry.Registry, *memory.MemoryStore, *api.Server,

	*httptest.Server) {
	return setupTTFTFailoverServerWithConfig(t, api.ServerConfig{})
}

func setupTTFTFailoverServerWithConfig(
	t *testing.T,
	cfg api.ServerConfig,

) (*registry.Registry, *memory.MemoryStore, *api.Server,

	*httptest.Server) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	// These fixtures exercise the opted-in SLA path. Explicit empty selects exemption.
	if cfg.FirstContentSLAAccounts == nil {
		cfg.FirstContentSLAAccounts = []string{testConsumerID}
	}
	srv := testkit.NewServer(t, reg, st, cfg, logger)
	srv.SetChallengeInterval(500 * time.Millisecond)
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
