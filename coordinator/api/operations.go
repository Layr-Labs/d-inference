package api

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/api/operations"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/telemetry/metrics"
)

// newOperations binds the read-only HTTP boundary to current server owners.
func (s *Server) newOperations() *operations.Controller {
	return operations.New(operations.Dependencies{
		Store:       func() operations.Store { return s.store },
		Metrics:     func() metrics.Snapshot { return s.metrics.Snapshot() },
		Utilization: func() registry.NetworkUtilization { return s.registry.NetworkUtilizationSnapshot() },
		Outcomes: func() operations.OutcomeCounters {
			if s.requestOutcomes == nil {
				return nil
			}
			return s.requestOutcomes
		},
		AuthorizeTelemetry: s.requireAdminKey,
		AuthorizeMetrics:   s.isAdminAuthorized,
		Logger:             func() *slog.Logger { return s.logger },
	})
}
