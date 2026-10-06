package demand_test

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/demand"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// Retain the actual registry, store and observation owner used by the callback.
type serverFixture struct {
	registry     *registry.Registry
	store        store.Store
	observation  *observation.Owner
	boundProfile *registry.RequestProfile
}

func newDemandObservationFixture(t *testing.T, d *demand.Request) *serverFixture {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	f := &serverFixture{registry: registry.New(logger), store: memory.NewMemory(store.Config{AdminKey: "test-key"})}
	f.observation = observation.New(observation.Dependencies{
		Registry: f.registry, Store: f.store, Logger: logger,
		Hooks: observation.Hooks{
			HasAutopilotDemand: func(context.Context) bool { return d != nil },
			BindAutopilotDemandProfile: func(_ *http.Request, rp *registry.RequestProfile) {
				f.boundProfile = rp
				d.BindProfile(rp)
			},
		},
	})
	t.Cleanup(f.observation.Close)
	return f
}

func completeDemandProfile(rp *registry.RequestProfile) {
	if rp == nil {
		return
	}
	rp.DoneFlushedUS.Store(20_000_000)
	ap := rp.NewAttempt("winner", 1, "loser")
	ap.Winning.Store(true)
	ap.ProviderCompleteObserved.Store(true)
	ap.SetOutcome("success", "", "", "completed", "")
	ap.SetTerminalUsage(25, 2)
}
