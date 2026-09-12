package registry

import (
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

type modelAutopilotController struct {
	registry    *Registry
	config      AutopilotConfig // immutable after construction
	demand      autopilotDemandTracker
	tickMu      sync.Mutex       // only ticks; never acquired by heartbeat or routing
	lastSummary AutopilotSummary // guarded by registry.mu
	running     bool             // guarded by registry.mu; prevents duplicate control goroutines
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

type autopilotModelFit struct {
	Rate           float64 // sustainable request equivalents/sec for this workload
	ServiceSeconds float64
	LoadSeconds    float64
	WeightsGiB     float64 // padded incoming transient
	Restricted     bool
	Measured       bool
	MeetsDeadline  bool
}
type autopilotNode struct {
	ID                     string
	Session                *Provider
	Seq                    uint64
	Managed, Idle, Pending bool
	MemoryPressure         float64
	State                  *protocol.ModelAutopilotState
	Residents              []string
	Fits                   map[string]autopilotModelFit
	Future                 map[string]float64
	FutureResidents        []string
	Uncertain              bool
}
type autopilotFleet struct {
	Nodes         []autopilotNode
	Demand        map[string]autopilotDemandView
	Floors        map[string]int
	Occupancy     map[string]int
	LegacyPending int
	Excluded      map[string]int
}
type autopilotAction struct {
	Node    autopilotNode
	Load    string
	Unload  []string
	Benefit float64
	Future  map[string]float64
}

// Summaries expose bounded model-level diagnostic counts, never identities or
// request content. The startup flags and these observations support shadow runs.
type AutopilotModelSummary struct {
	Model           string  `json:"model"`
	LogicalRequests int     `json:"logical_requests"`
	OfferedRPS      float64 `json:"offered_rps"`
	CapacityRPS     float64 `json:"capacity_rps"`
	PendingRPS      float64 `json:"pending_rps"`
	ProtectedFloor  int     `json:"protected_floor"`
	WarmProviders   int     `json:"warm_providers"`
	EligibleIdle    int     `json:"eligible_idle"`
	DeficitRPS      float64 `json:"deficit_rps"`
}
type AutopilotSummary struct {
	At          time.Time               `json:"at"`
	ObserveOnly bool                    `json:"observe_only"`
	OptedIn     int                     `json:"opted_in"`
	Pending     int                     `json:"pending"`
	Proposed    int                     `json:"proposed"`
	Issued      int                     `json:"issued"`
	Uncertain   int                     `json:"uncertain"`
	Excluded    map[string]int          `json:"excluded"`
	Models      []AutopilotModelSummary `json:"models"`
}
