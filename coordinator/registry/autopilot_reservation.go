package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotcontrol"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func (r *Registry) beginAutopilotReservation(c *modelAutopilotController, now time.Time) (autopilotcontrol.Reservation[*Provider], bool) {
	// Demand retains its leaf lock. The exclusive registry lease then prevents
	// new admissions and binds existing provider updates before donor replanning.
	demand := c.demand.ShapeSnapshot(now, c.config.DemandWindow)
	r.mu.Lock()
	if r.autopilot != c || !c.config.Enabled || c.config.ObserveOnly || c.paused.Load() {
		r.mu.Unlock()
		return autopilotcontrol.Reservation[*Provider]{}, false
	}
	return autopilotcontrol.Reservation[*Provider]{
		Fleet: r.autopilotFleetSnapshotLocked(c, demand, now), Release: r.mu.Unlock,
		Commit: func(a autopilotAction, cmd protocol.ModelAutopilotMessage, now time.Time) bool {
			p := a.Session
			p.mu.Lock()
			defer p.mu.Unlock()
			if p.capacitySeq != a.Node.Seq || providerAutopilotTransitionLocked(p) || p.pendingCount() != 0 || !providerAutopilotManagedLocked(p) {
				return false
			}
			p.autopilotState.Reserve(cmd, p.capacitySeq, now, c.config.FailureBackoff)
			p.recordDeadlineActivityLocked(now)
			return true
		},
	}, true
}
