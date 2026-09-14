// Package attempt owns cancellation delivery and provider-health feedback for
// inference attempts. Provider ingress, dispatch and response handling share the
// same cancellation tracker and bind their existing live services.
package attempt

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type Store interface {
	GetModelRegistryRecord(model string) (*store.ModelRegistryRecord, error)
}

type Reservations interface {
	RefundProviderExtra(pr *registry.PendingRequest)
}

type Metrics interface {
	Incr(name string, tags []string)
	Histogram(name string, value float64, tags []string)
}

// Dependencies preserves live registry/store/reservation lookups while Tracker
// holds the one startup-owned cancellation map. UnknownFrame observes the
// existing bounded API counters; it does not participate in cancellation.
type Dependencies struct {
	Registry     func() *registry.Registry
	Store        func() Store
	Reservations func() Reservations
	Logger       func() *slog.Logger
	Metrics      Metrics
	Tracker      *Tracker
	UnknownFrame func(kind string, provider *registry.Provider)
}

type Service struct{ deps Dependencies }

func New(deps Dependencies) Service { return Service{deps: deps} }
