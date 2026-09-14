package warmpool

import (
	"time"
)

type Snapshot[A any] struct {
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
	Actions            []A

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
	OccupancyRamp      float64
	HeadroomProviders  int
	ServiceTime        time.Duration
	QualityConcurrency int
	DemandConcurrency  float64

	// ColdIneligible is the count of cold (on-disk, not-warm) providers advertising
	// the model that failed the warm-pool candidate gate this tick, with
	// ColdDisqualifiers breaking it down by reason (warmColdReason). Diagnoses why
	// the eligible-cold set (and thus the warmable target) is smaller than the raw
	// cold-provider count — counts only, no provider identities.
	ColdIneligible    int
	ColdDisqualifiers map[string]int
}

func (c *Controller[A]) storeSnapshots(snaps []Snapshot[A], now time.Time) {
	cp := make([]Snapshot[A], len(snaps))
	copy(cp, snaps)
	c.lastMu.Lock()
	c.lastSnaps = cp
	c.lastSnapsAt = now
	c.lastMu.Unlock()
}

func (c *Controller[A]) LatestSnapshots() ([]Snapshot[A], time.Time) {
	c.lastMu.RLock()
	defer c.lastMu.RUnlock()
	if len(c.lastSnaps) == 0 {
		return nil, c.lastSnapsAt
	}
	cp := make([]Snapshot[A], len(c.lastSnaps))
	copy(cp, c.lastSnaps)
	return cp, c.lastSnapsAt
}
