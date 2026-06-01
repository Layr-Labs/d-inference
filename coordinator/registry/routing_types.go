package registry

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

type routingSnapshot struct {
	provider           *Provider
	model              string
	slotState          string
	hasHeadroom        bool
	totalPending       int
	pendingForModel    int
	pendingMaxTokens   int
	backendRunning     int
	backendWaiting     int
	maxTokensPotential int64
	decodeTPS          float64
	prefillTPS         float64
	systemMetrics      protocol.SystemMetrics
	gpuMemoryActiveGB  float64
	totalMemoryGB      float64
	modelSizeGB        float64 // catalog-reported weight footprint (0 = unknown, gate disabled)
	modelLoaded        bool    // true when the requested model is the currently-running slot
	availableOnDisk    bool    // model is in provider's Models list but not currently loaded

	observedDecodeTPS     float64
	activeTokenBudgetUsed int64
	activeTokenBudgetMax  int64
	queuedTokenBudget     int64
	fleetMedianTPS        float64
}

type routingCandidate struct {
	provider       *Provider
	snapshot       routingSnapshot
	costMs         float64
	effectiveQueue int
	breakdown      costBreakdown
	effectiveTPS   float64 // Phase 4 load-scaled TPS used in this candidate's cost
}

// candidateRejection enumerates why a provider that passed structural
// gates (status, trust, slot state, thermal) was nonetheless excluded
// from selection. Used to populate RoutingDecision counters so callers
// can distinguish "no provider serves this model" from "every fitting
// provider is full".
type candidateRejection int

const (
	rejectNone candidateRejection = iota
	rejectCapacity
)

// costBreakdown decomposes the routing cost so callers can log or
// expose individual contributions. The numeric values match the terms
// added in buildCandidate; total should equal costMs (modulo float
// rounding).
type costBreakdown struct {
	StateMs   float64
	QueueMs   float64
	PendingMs float64
	BacklogMs float64
	ThisReqMs float64
	HealthMs  float64
	Total     float64
}

// RoutingDecision is the public, exportable record of a routing
// selection. Returned by ReserveProviderEx so callers can emit metrics
// and structured logs without reaching into registry internals.
type RoutingDecision struct {
	ProviderID         string  // winning provider, empty if no selection
	Model              string  // requested model
	CostMs             float64 // total cost of the winning candidate
	StateMs            float64 // slot-state penalty contribution
	QueueMs            float64 // pendingForModel × queueDepthPenaltyMs
	PendingMs          float64 // totalPending × totalPendingPenaltyMs
	BacklogMs          float64 // tokens-ahead / decodeTPS contribution
	ThisReqMs          float64 // this request's prefill+decode contribution
	HealthMs           float64 // memory/CPU/thermal/GPU-util contribution
	EffectiveQueue     int     // max(pendingForModel, backendRunning+backendWaiting)
	CandidateCount     int     // total candidates that passed all gates
	CapacityRejections int     // candidates rejected by the free-memory admission gate
	EffectiveTPS       float64 // load-scaled decode TPS used in cost (Phase 4)
	StaticTPS          float64 // benchmarked decode TPS before load scaling
}
