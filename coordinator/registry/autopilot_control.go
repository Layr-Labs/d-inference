package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotcontrol"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (r *Registry) newAutopilotControl(c *modelAutopilotController) autopilotcontrol.Operations[*Provider] {
	control := autopilotcontrol.New(c.config, autopilotcontrol.Ports[*Provider]{
		Snapshot: func(now time.Time) autopilotFleet { return r.autopilotFleetSnapshot(c, now) },
		BeginReservation: func(now time.Time) (autopilotcontrol.Reservation[*Provider], bool) {
			return r.beginAutopilotReservation(c, now)
		},
		Flush: r.flushAutopilotEvents, Refresh: c.refreshControlLeases,
		Watchdogs: func(now time.Time) { r.markAutopilotWatchdogs(c.config, now) },
		Retry:     r.retryAutopilotCommands,
		Paused:    c.paused.Load, Pause: func() { c.paused.Store(true) },
		Propose: func(action autopilotAction, now time.Time) {
			r.queueAutopilotEvent(store.AutopilotRecord{Reason: action.Reason, Shape: autopilot.ShapeLabel(action.Workload), CommandID: autopilotProposalID(action), At: now, ProviderID: action.Node.ID, Phase: "proposed", Load: action.Load, Unload: action.Unload, Before: autopilot.ResidentIDs(action.Node.State), Benefit: action.Benefit})
		},
		Deliver: r.prepareAutopilotDelivery,
		Send:    r.sendAutopilotCommand,
		Publish: func(summary autopilot.Summary, started time.Time) {
			r.mu.Lock()
			c.lastSummary = summary
			r.mu.Unlock()
			if r.logger != nil {
				r.logger.Info("model autopilot tick", "duration_ms", float64(time.Since(started).Microseconds())/1000, "observe_only", summary.ObserveOnly, "opted_in", summary.OptedIn, "pending", summary.Pending, "uncertain", summary.Uncertain, "proposed", summary.Proposed, "issued", summary.Issued, "excluded", summary.Excluded, "models", summary.Models)
			}
		},
	})
	if r.autopilotControlFactory != nil {
		return r.autopilotControlFactory(control)
	}
	return control
}
