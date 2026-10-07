package resume

import (
	"context"
	"log/slog"

	codeidentity "github.com/eigeninference/d-inference/coordinator/internal/provider/identity"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type Recovery func(context.Context, string, *registry.Provider)

type Manager struct {
	codeAttestThrottle *codeidentity.Throttle
	logger             *slog.Logger
	transport          Transport
	recover            Recovery
}

func New(throttle *codeidentity.Throttle, logger *slog.Logger, transport Transport, recovery Recovery) *Manager {
	if transport == nil {
		transport = ProviderTransport{}
	}
	return &Manager{codeAttestThrottle: throttle, logger: logger, transport: transport, recover: recovery}
}
