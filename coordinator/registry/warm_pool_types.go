package registry

import (
	"sync"
	"time"
)

type warmPoolController struct {
	registry *Registry
	config   WarmPoolConfig
	state    *warmPoolState
	queueMu  syncQueuePressure
	tickMu   sync.Mutex
	triggerC chan struct{}

	// lastMu guards the most recent set of per-model snapshots produced by tick.
	// They are cached read-only so observability paths (network utilization
	// gauges, /v1/stats, /v1/admin/utilization) can read the Little's Law
	// diagnostics the controller already computes without re-running a planning
	// pass (which has model-load side effects).
	lastMu      sync.RWMutex
	lastSnaps   []WarmPoolSnapshot
	lastSnapsAt time.Time
}

type syncQueuePressure struct {
	mu     sync.Mutex
	models map[string]warmPoolQueuePressure
}

type warmPoolQueuePressure struct {
	Depth     int
	OldestAge time.Duration
	UpdatedAt time.Time
}

type WarmPoolSnapshot struct {
	Model              string
	TargetWarm         int
	WarmProviders      int
	EligibleCold       int
	QueueDepth         int
	OldestQueueAge     time.Duration
	CapacityRejects    int
	TTFTMisses         int
	SpeculativeStarted int
	SpeculativeWon     int
	ColdDispatches     int
	LoadDurationEWMA   time.Duration
	ObserveOnly        bool
	Actions            []modelLoadAction

	// Little's Law diagnostics (Layer 3, routing-v2.md). DemandConcurrency is
	// L = λ·E[S]; QualityConcurrency is the per-provider batch ceiling at the
	// decode floor; SpillArrivalRate is the EWMA arrivals/sec the pool shed.
	RunningRequests int
	WaitingRequests int
	WarmSaturated   int // warm providers with NO concurrency headroom left
	// WarmForeignBlocked is the subset of WarmSaturated saturated by a CO-RESIDENT
	// model (no headroom, none of THIS model's requests in flight). It is added to
	// the headroom floor because that load never appears in running/waiting.
	WarmForeignBlocked int
	SpillArrivalRate   float64
	// OccupancyRamp is the measured demand-growth EWMA (slots/interval) and
	// HeadroomProviders the floor derived from it — the two numbers needed to
	// audit why a model's proactive target is what it is.
	OccupancyRamp        float64
	HeadroomProviders    int
	ServiceTime          time.Duration
	QualityConcurrency   int
	DemandConcurrency    float64
	MeasuredPromptTokens float64
	MeasuredOutputTokens float64
	PromptWorkTPS        float64
	GenerationWorkTPS    float64
	AggregateDecodeTPS   float64
	WorkProviders        float64

	// ColdIneligible is the count of cold (on-disk, not-warm) providers advertising
	// the model that failed the warm-pool candidate gate this tick, with
	// ColdDisqualifiers breaking it down by reason (warmColdReason). Diagnoses why
	// the eligible-cold set (and thus the warmable target) is smaller than the raw
	// cold-provider count — counts only, no provider identities.
	ColdIneligible    int
	ColdDisqualifiers map[string]int
}

type warmPoolModelSnapshot struct {
	model         string
	warm          int
	warmSaturated int
	// warmForeignBlocked is the subset of warmSaturated whose saturation is NOT
	// explained by this model's own load: the provider has the weights resident
	// but zero concurrency headroom while running NONE of this model's requests,
	// so a co-resident model consumed its capacity. Those requests are absent
	// from this model's running/waiting, so such a provider contributes qc to
	// nominal capacity while being able to serve nothing — see headroomTarget.
	warmForeignBlocked int
	// running / waiting are the in-flight load summed across warm providers'
	// backend slots for this model (the observable L in Little's Law).
	running int
	waiting int
	// soloDecodeTPS / serviceDecodeTPS / prefillTPS / maxProviderConc are
	// representative (median) rates and the per-provider concurrency cap across
	// providers serving the model. soloDecodeTPS is the STATIC solo rate from
	// the quality-cap resolver (resolvedSoloModelTPSLocked) and feeds quality
	// concurrency, so warm targets and admission caps use the same math and
	// cannot disagree. serviceDecodeTPS keeps the observed-EWMA-preferring
	// chain (resolvedModelTPSLocked) and feeds only the E[S] service-time
	// estimate, which deliberately wants the load-inclusive rate a request
	// actually sees.
	soloDecodeTPS      float64
	serviceDecodeTPS   float64
	prefillTPS         float64
	maxProviderConc    int
	qualityConc        int
	aggregateDecodeTPS float64
	workProviders      float64
	eligibleCold       []warmPoolCandidate
	// coldIneligible / coldDisq tally cold (on-disk, not-warm) providers that
	// FAILED the warm-pool candidate gate, by reason — diagnostics for why
	// eligibleCold is smaller than the raw cold count.
	coldIneligible int
	coldDisq       map[warmColdReason]int
}

type warmPoolCandidate struct {
	providerID           string
	score                float64
	recentResidentModels int
}
