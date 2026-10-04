// Package provider owns provider socket sessions and typed protocol delivery.
package provider

import (
	"log/slog"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/catalog"
	"github.com/eigeninference/d-inference/coordinator/api/geo"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/api/provider/trust"
	"github.com/eigeninference/d-inference/coordinator/api/releases"
	"github.com/eigeninference/d-inference/coordinator/internal/provider/heartbeat"
	"github.com/eigeninference/d-inference/coordinator/internal/provider/inventory"
	"github.com/eigeninference/d-inference/coordinator/internal/provider/session"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// InferenceEvents hands off already-decoded frames. CompleteAt preserves the
// ingress timestamp and stays inside the session's existing terminal barrier.
type InferenceEvents struct {
	Chunk      func(string, *registry.Provider, *protocol.InferenceResponseChunkMessage)
	Accepted   func(*registry.Provider, *protocol.InferenceAcceptedMessage)
	CompleteAt func(string, *registry.Provider, *protocol.InferenceCompleteMessage, time.Time)
	Error      func(string, *registry.Provider, *protocol.InferenceErrorMessage)
}

type Dependencies struct {
	Registry    *registry.Registry
	Store       store.Store
	Trust       *trust.Owner
	Releases    *releases.Owner
	Catalog     *catalog.Owner
	Geo         geo.Resolver
	Observation *observation.Owner
	Logger      *slog.Logger
	Inference   InferenceEvents
	Sessions    *session.Gate
}

type Owner struct {
	registry    *registry.Registry
	store       store.Store
	trust       *trust.Owner
	releases    *releases.Owner
	catalog     *catalog.Owner
	geoResolver geo.Resolver
	observation *observation.Owner
	logger      *slog.Logger
	inference   InferenceEvents
	sessions    *session.Gate
	heartbeat   *heartbeat.Ingestor
	inventory   *inventory.Controller
}

func New(d Dependencies) *Owner {
	if d.Sessions == nil {
		d.Sessions = &session.Gate{}
	}
	// Catalog is optional for owners that only restore persisted state.
	var supportsDesiredModels func(string) bool
	if d.Catalog != nil {
		supportsDesiredModels = d.Catalog.ProviderSupportsDesiredModels
	}
	return &Owner{registry: d.Registry, store: d.Store, trust: d.Trust, releases: d.Releases,
		catalog: d.Catalog, geoResolver: d.Geo, observation: d.Observation, logger: d.Logger, inference: d.Inference,
		sessions: d.Sessions, heartbeat: heartbeat.New(d.Registry, d.Observation),
		inventory: inventory.New(d.Registry, supportsDesiredModels, d.Logger)}
}

// SetInferenceEvents is setup-only; sessions must not be running yet.
func (s *Owner) SetInferenceEvents(events InferenceEvents) { s.inference = events }
