package push

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/apns"
	codeidentity "github.com/eigeninference/d-inference/coordinator/internal/provider/identity"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// codePushDispatcher emits only generation- and identity-bound pushes. Its
// caller retains the reservation lease through the entire dispatch operation.
type Dispatcher struct {
	registry           *registry.Registry
	observation        *observation.Owner
	logger             *slog.Logger
	codeAttestor       apns.CodeIdentityAttestor
	codeAttestThrottle *codeidentity.Throttle
}

func New(reg *registry.Registry, obs *observation.Owner, logger *slog.Logger, throttle *codeidentity.Throttle) *Dispatcher {
	return &Dispatcher{registry: reg, observation: obs, logger: logger, codeAttestThrottle: throttle}
}

func (s *Dispatcher) AlertMode() bool {
	if mode, ok := s.codeAttestor.(interface{ Mode() apns.Mode }); ok {
		return mode.Mode() == apns.ModeAlert
	}
	return false
}
