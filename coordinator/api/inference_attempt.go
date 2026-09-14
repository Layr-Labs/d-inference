package api

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// inferenceAttempts binds the shared cancellation tracker to the same live
// registry, financial service and observations used by provider ingress.
func (s *Server) inferenceAttempts() attempt.Service {
	return attempt.New(attempt.Dependencies{
		Registry:     func() *registry.Registry { return s.registry },
		Store:        func() attempt.Store { return s.store },
		Reservations: func() attempt.Reservations { return s.inferenceSettlement() },
		Logger:       func() *slog.Logger { return s.logger },
		Tracker:      s.attemptTracker,
		Metrics:      inferenceMetrics{server: s},
		UnknownFrame: s.emitUnknownFrame,
	})
}
