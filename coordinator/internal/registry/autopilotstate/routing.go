package autopilotstate

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// RoutingBlocked applies only the Autopilot residency fence. The registry still
// owns catalog, trust, capacity and other request-specific admission gates.
func (s *State) RoutingBlocked(state *protocol.ModelAutopilotState, session, model string, capacity *protocol.BackendCapacity, now func() time.Time) bool {
	if !s.OrdinaryAllowed(state, session, model, now) {
		return true
	}
	if s.Transition(state) {
		return true
	}
	if !s.managedNow(state, session, now) {
		return false
	}
	if capacity != nil {
		for _, slot := range capacity.Slots {
			if slot.Model == model {
				return slot.State != "running" && slot.State != "idle"
			}
		}
	}
	return true
}

// LegacyChangesBlocked keeps accepted operations fenced even after their grant
// expires. Consent without activation does not take ordinary model ownership.
func (s *State) LegacyChangesBlocked(state *protocol.ModelAutopilotState, session string, now func() time.Time) bool {
	return s.managedNow(state, session, now) || s.Transition(state)
}
