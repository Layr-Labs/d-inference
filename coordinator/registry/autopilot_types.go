package registry

import (
	"sync/atomic"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotcontrol"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

type modelAutopilotController struct {
	paused      atomic.Bool
	registry    *Registry
	config      autopilot.Config // immutable after construction
	demand      *autopilot.DemandTracker
	control     autopilotcontrol.Operations[*Provider]
	lastSummary autopilot.Summary // guarded by registry.mu
	running     bool              // guarded by registry.mu; prevents duplicate control goroutines
}

// Snapshots retain session identity in the registry adapter, never in policy.
type autopilotFleet = autopilotcontrol.Fleet[*Provider]
type autopilotAction = autopilotcontrol.Action[*Provider]
