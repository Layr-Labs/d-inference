package deviceverification

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	trustauthority "github.com/eigeninference/d-inference/coordinator/internal/provider/authority"
	"github.com/eigeninference/d-inference/coordinator/internal/provider/verification"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// mdmBackend binds the MDM transport and scheduler used by registration,
// challenge settlement, callbacks and verification execution. Both are wired
// before serving; every consumer retains this same binding on replacement.
type Backend struct {
	Client    *mdm.Client
	Scheduler *verification.Service
}

type Dependencies struct {
	Registry         *registry.Registry
	Store            store.Store
	Observation      *observation.Owner
	Logger           *slog.Logger
	Backend          *Backend
	Authority        *trustauthority.Service
	SendTrustStatus  func(*registry.Provider, registry.TrustLevel, string, string)
	LegacyMDMAllowed func(*registry.Provider) bool
}

type Verifier struct {
	registry            *registry.Registry
	store               store.Store
	observation         *observation.Owner
	logger              *slog.Logger
	verificationBackend *Backend
	authority           *trustauthority.Service
	sendTrustStatus     func(*registry.Provider, registry.TrustLevel, string, string)
	legacyMDMAllowed    func(*registry.Provider) bool
}

func New(d Dependencies) *Verifier {
	return &Verifier{
		registry: d.Registry, store: d.Store, observation: d.Observation, logger: d.Logger,
		verificationBackend: d.Backend, authority: d.Authority, sendTrustStatus: d.SendTrustStatus,
		legacyMDMAllowed: d.LegacyMDMAllowed,
	}
}
