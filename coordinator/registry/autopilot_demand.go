package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

func (r *Registry) AutopilotEnabled() bool {
	r.mu.RLock()
	c := r.autopilot
	r.mu.RUnlock()
	return c != nil && c.config.Enabled
}

func (r *Registry) RecordAutopilotDemand(sample autopilot.DemandSample) {
	r.mu.RLock()
	c := r.autopilot
	r.mu.RUnlock()
	if c == nil || !c.config.Enabled {
		return
	}
	c.demand.Record(sample, time.Now(), c.config.DemandWindow)
}
