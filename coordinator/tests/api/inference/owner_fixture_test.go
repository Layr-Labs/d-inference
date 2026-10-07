package inference_test

import (
	"io"
	"log/slog"

	inference "github.com/eigeninference/d-inference/coordinator/api/inference"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Unit tests retain the dependencies they pass to the real owner. Router tests
// instead use serverFixture, whose embedded owner belongs to the real API graph.
type ownerFixture struct {
	*inference.Owner
	registry    *registry.Registry
	store       store.Store
	ledger      *payments.Ledger
	observation *observation.Owner
}

func newOwnerFixture(reg *registry.Registry, st store.Store, logger *slog.Logger) *ownerFixture {
	f := &ownerFixture{
		registry: reg, store: st, ledger: payments.NewLedger(st),
		observation: observation.New(observation.Dependencies{Registry: reg, Store: st, Logger: logger}),
	}
	f.Owner = inference.New(inference.Dependencies{
		Registry: reg, Store: st, Ledger: f.ledger, Observation: f.observation, Logger: logger,
	}, inference.Config{})
	return f
}

func (f *ownerFixture) Close() {
	f.CloseResources()
	f.observation.Close()
}

func quietLogger() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

const (
	envProfiler       = "EIGENINFERENCE_PROFILER"
	SealedContentType = inference.SealedContentType
)
