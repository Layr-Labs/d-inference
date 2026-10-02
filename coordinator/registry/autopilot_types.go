package registry

import (
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

type modelAutopilotController struct {
	paused      atomic.Bool
	registry    *Registry
	config      autopilot.Config // immutable after construction
	demand      autopilot.DemandTracker
	tickMu      sync.Mutex        // only ticks; never acquired by heartbeat or routing
	lastSummary autopilot.Summary // guarded by registry.mu
	running     bool              // guarded by registry.mu; prevents duplicate control goroutines
}

type autopilotPendingCommand struct {
	Command        protocol.ModelAutopilotMessage
	SentAt         time.Time
	CapacitySeq    uint64
	Status         string
	Uncertain      bool
	LastSentAt     time.Time
	Attempts       int
	FailureBackoff time.Duration
}

// Snapshots retain session identity in the registry adapter, never in policy.
type autopilotFleet struct {
	autopilot.Fleet
	sessions map[string]*Provider
}
type autopilotAction struct {
	autopilot.Action
	session *Provider
}
