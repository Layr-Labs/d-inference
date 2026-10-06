package testbed

import (
	"encoding/json"
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Capture under the registry locks, then log outside them. Startup can fail
// before the test body installs its own diagnostics; preserve resource and
// consent evidence while the isolated provider is still registered.
func logAutopilotStartupDiagnostics(reg *registry.Registry, logger *slog.Logger) {
	var snapshots []string
	reg.ForEachProviderVerification(func(p *registry.Provider, _ registry.Verification, models registry.PublicProviderModelSnapshot) {
		data, err := json.Marshal(map[string]any{
			"status": p.Status, "models": models.Models,
			"system_metrics": p.SystemMetrics, "autopilot": p.ModelAutopilot,
		})
		if err == nil {
			snapshots = append(snapshots, string(data))
		}
	})
	for _, snapshot := range snapshots {
		logger.Info("autopilot startup waiting for backend", "provider_state", snapshot)
	}
}
