package challenge

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/api/releases"
	trustauthority "github.com/eigeninference/d-inference/coordinator/internal/provider/authority"
	codeattest "github.com/eigeninference/d-inference/coordinator/internal/provider/codeidentity"
	"github.com/eigeninference/d-inference/coordinator/internal/provider/deviceverification"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type Dependencies struct {
	Registry        *registry.Registry
	Releases        *releases.Owner
	Observation     *observation.Owner
	Logger          *slog.Logger
	Configuration   *Configuration
	Policy          *Policy
	Authority       *trustauthority.Service
	Identity        *codeattest.Controller
	Device          *deviceverification.Verifier
	Backend         *deviceverification.Backend
	SendTrustStatus func(*registry.Provider, registry.TrustLevel, string, string)
}

// challengeEngine verifies live signed posture and coordinates the independent
// hardware, runtime and application evidence authorities after each challenge.
type Engine struct {
	*Policy
	registry            *registry.Registry
	releases            *releases.Owner
	observation         *observation.Owner
	logger              *slog.Logger
	challengeSettings   *Configuration
	authority           *trustauthority.Service
	identity            *codeattest.Controller
	device              *deviceverification.Verifier
	verificationBackend *deviceverification.Backend
	sendTrustStatus     func(*registry.Provider, registry.TrustLevel, string, string)
}

func NewEngine(d Dependencies) *Engine {
	return &Engine{
		Policy: d.Policy, registry: d.Registry, releases: d.Releases,
		observation: d.Observation, logger: d.Logger, challengeSettings: d.Configuration,
		authority: d.Authority, identity: d.Identity, device: d.Device, verificationBackend: d.Backend,
		sendTrustStatus: d.SendTrustStatus,
	}
}
