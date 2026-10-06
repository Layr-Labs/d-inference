package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Called only for accepted replacements under p.mu. Rejected capacity frames
// advance liveness independently and leave this clock untouched.
func (p *Provider) reconcileCapacitySamplesLocked(current *protocol.BackendCapacity, now time.Time) {
	if p.capacitySamples == nil {
		p.capacitySamples = &capacityvalue.SampleHistory{}
	}
	p.capacitySamples.Reconcile(p.BackendCapacity, current, now)
}
