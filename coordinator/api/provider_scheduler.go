package api

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/providercontrol/mdmscheduler"
	"github.com/eigeninference/d-inference/coordinator/telemetry/metrics"
)

// Claims use the startup store. Verification, persistence and telemetry retain
// the API's current bindings when each operation runs.
func (s *Server) mdmSchedulerDependencies() mdmscheduler.Dependencies {
	return mdmscheduler.Dependencies{
		Store:    s.store,
		Registry: func() mdmscheduler.Registry { return s.registry },
		Logger:   func() *slog.Logger { return s.logger },
		Metrics:  func() *metrics.Registry { return s.metrics },
		Counter:  s.ddIncr, Gauge: s.ddGauge, Histogram: s.ddHistogram,
		Verifier: func() mdmscheduler.Verifier { return s.newProviderVerifier() },
	}
}
