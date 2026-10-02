package registry

import (
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"time"
)

func planAutopilotAction(f autopilotFleet, cfg autopilot.Config, now time.Time) *autopilotAction {
	action := autopilot.Plan(f.Fleet, cfg, now)
	if action == nil {
		return nil
	}
	session := f.sessions[action.Node.ID]
	if session == nil {
		return nil
	}
	return &autopilotAction{Action: *action, session: session}
}
func autopilotCoverage(f autopilotFleet) autopilot.CoverageView {
	return autopilot.Coverage(f.Fleet)
}
func autopilotSummary(f autopilotFleet, cfg autopilot.Config, now time.Time) autopilot.Summary {
	return autopilot.Summarize(f.Fleet, cfg, now)
}
