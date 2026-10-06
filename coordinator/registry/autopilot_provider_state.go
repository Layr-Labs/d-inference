package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotstate"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

func providerAutopilotManagedLocked(p *Provider) bool {
	return p.autopilotState.Managed(p.ModelAutopilot, p.ID, time.Now())
}

func providerAutopilotControlActiveLocked(p *Provider) bool {
	return p.autopilotState.ControlActive(p.ModelAutopilot, p.ID, time.Now())
}
func providerAutopilotTransitionLocked(p *Provider) bool {
	return p.autopilotState.Transition(p.ModelAutopilot)
}

func autopilotStateMatchesCapacity(p *Provider) bool {
	return autopilot.StateMatchesCapacity(p.ModelAutopilot, p.BackendCapacity, p.capacitySeq)
}

// Called only after the accepted capacity-sequence gate, under p.mu. Status
// messages alone never clear reservations or manufacture warm slot capacity.
func (r *Registry) reconcileAutopilotHeartbeatLocked(p *Provider, state *protocol.ModelAutopilotState, reported *protocol.BackendCapacity, now time.Time) {
	p.ModelAutopilot = autopilot.CloneState(state)
	if p.autopilotState.Reconcile(p.ID, state, reported, p.capacitySeq, now, r.queueAutopilotEvent) {
		p.recordDeadlineActivityLocked(now)
	}
}

func (r *Registry) newAutopilotState(id string) *autopilotstate.State {
	if r.autopilotStateFactory != nil {
		if state := r.autopilotStateFactory(id); state != nil {
			return state
		}
	}
	return &autopilotstate.State{}
}
