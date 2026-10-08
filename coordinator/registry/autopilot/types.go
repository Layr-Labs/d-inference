package autopilot

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/residency"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

type ModelFit = residency.ModelFit
type Node struct {
	ID                     string
	Seq                    uint64
	Managed, Idle, Pending bool
	Consented, ObserveOnly bool // public consent and effective per-machine control mode
	ControlActive          bool // matching acknowledged live grant, not placement eligibility
	MemoryPressure         float64
	State                  *protocol.ModelAutopilotState
	Residents              []string
	Fits                   map[string]ModelFit
	HypotheticalResidents  []string // after-activation permission, never live donor evidence
	HypotheticalFits       map[string]ModelFit
	Future                 map[string]float64
	FutureResidents        []string
	UnscopedBusy           bool // private/local or unattributed GPU work cannot supply public capacity
	Uncertain              bool
}
type Fleet struct {
	Nodes         []Node
	Demand        map[string]DemandView
	Floors        map[string]int
	LegacyPending int
	Excluded      map[string]int
}
type Action struct {
	Workload string
	Reason   string
	Node     Node
	Load     string
	Unload   []string
	Benefit  float64
	Future   map[string]float64
}

// Summaries expose bounded model-level diagnostic counts, never identities or
// request content. The startup flags and these observations support shadow runs.
type ModelSummary struct {
	Shape            string  `json:"shape,omitempty"`
	Model            string  `json:"model"`
	LogicalRequests  int     `json:"logical_requests"`
	QueuedRequests   int     `json:"queued_requests"`
	InFlightRequests int     `json:"public_inflight_requests"`
	OfferedRPS       float64 `json:"offered_rps"`
	CapacityRPS      float64 `json:"capacity_rps"`
	PendingRPS       float64 `json:"pending_rps"`
	ProtectedFloor   int     `json:"protected_floor"`
	WarmProviders    int     `json:"warm_providers"`
	EligibleIdle     int     `json:"eligible_idle"`
	DeficitRPS       float64 `json:"deficit_rps"`
}
type Summary struct {
	Enabled        bool           `json:"enabled"`
	Running        bool           `json:"running"`
	Paused         bool           `json:"paused"`
	At             time.Time      `json:"at"`
	ObserveOnly    bool           `json:"observe_only"`
	OptedIn        int            `json:"opted_in"`
	LiveCohort     int            `json:"live_cohort"`
	LiveActive     int            `json:"live_active"`
	Shadow         int            `json:"shadow"`
	Pending        int            `json:"pending"`
	Proposed       int            `json:"proposed"`
	LiveProposed   int            `json:"live_proposed"`
	ShadowProposed int            `json:"shadow_proposed"`
	Issued         int            `json:"issued"`
	Uncertain      int            `json:"uncertain"`
	Excluded       map[string]int `json:"excluded"`
	Models         []ModelSummary `json:"models"`
}
