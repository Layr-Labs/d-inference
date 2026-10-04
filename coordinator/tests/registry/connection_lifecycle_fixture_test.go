package registry_test

import (
	"log/slog"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func newConnectionLifecycleRegistry(logger *slog.Logger, deps production.Dependencies) (*production.Registry, *production.ConnectionLifecycle) {
	var lifecycle *production.ConnectionLifecycle
	deps.ConnectionLifecycle = func(owner *production.ConnectionLifecycle) production.ConnectionMaintenance {
		lifecycle = owner
		return owner
	}
	r := production.NewWithDependencies(logger, deps)
	return r, lifecycle
}
