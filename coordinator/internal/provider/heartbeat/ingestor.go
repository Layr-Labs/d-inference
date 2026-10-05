// Package heartbeat applies ordered provider capacity updates and emits their
// operational telemetry without retaining request content.
package heartbeat

import (
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type Ingestor struct {
	registry    *registry.Registry
	observation *observation.Owner
}

func New(reg *registry.Registry, obs *observation.Owner) *Ingestor {
	return &Ingestor{registry: reg, observation: obs}
}
