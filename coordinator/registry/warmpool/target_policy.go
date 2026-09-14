package warmpool

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/throughput"
)

// targetParams snapshots the controller config into the pure Params
// consumed by the Little's Law math in target.go.
func (c planningPass[A]) targetParams() Params {
	return Params{
		DecodeFloorTPS:             c.config.DecodeFloorTPS,
		LoadFactorK:                throughput.LoadFactor,
		BurstBuffer:                c.config.BurstBuffer,
		HeadroomProviders:          c.config.HeadroomProviders,
		HeadroomEnabledParams:      c.config.HeadroomEnabled,
		HeadroomMaxProviders:       c.config.HeadroomMaxProviders,
		HeadroomLoadWindows:        c.config.HeadroomLoadWindows,
		FallbackQualityConcurrency: c.config.FallbackQualityConcurrency,
		AssumedPromptTokens:        c.config.AssumedPromptTokens,
		AssumedCompletionTokens:    c.config.AssumedCompletionTokens,
		MinServiceTime:             MinServiceTime,
		MaxServiceTime:             MaxServiceTime,
	}
}

// targetInputs assembles the measured per-model inputs for the Little's Law
// target from the fleet, pressure, and queue snapshots.
func (c planningPass[A]) targetInputs(fleet FleetModel, pressure Pressure, queue QueuePressure) Inputs {
	return Inputs{
		Model:              fleet.Model,
		Warm:               fleet.Warm,
		WarmSaturated:      fleet.WarmSaturated,
		WarmForeignBlocked: fleet.WarmForeignBlocked,
		EligibleCold:       len(fleet.EligibleCold),
		RunningRequests:    fleet.Running,
		WaitingRequests:    fleet.Waiting,
		QueueDepth:         queue.Depth,
		SpillArrivalRate:   pressure.ArrivalRateEWMA,
		OccupancyRamp:      pressure.OccupancyRampEWMA,
		SoloDecodeTPS:      fleet.SoloDecodeTPS,
		PrefillTPS:         fleet.PrefillTPS,
		MaxProviderConc:    fleet.MaxProviderConc,
		DemandPressure:     c.hasDemandPressure(fleet, pressure, queue),
	}
}

// hasDemandPressure reports whether any pressure signal crossed its threshold
// this window. It consumes ALL signals fed to the controller — capacity rejects,
// TTFT misses, cold dispatches, speculative starts/wins (now including the W3
// preflight-fed near-misses), an aged coordinator queue, and a saturated warm set
// under any external pressure. Proactive headroom and configured minimums can
// still grow the pool without a pressure event.
func (c planningPass[A]) hasDemandPressure(fleet FleetModel, pressure Pressure, queue QueuePressure) bool {
	if pressure.CapacityRejects >= c.config.CapacityRejectThreshold ||
		pressure.TTFTMisses >= c.config.TTFTMissThreshold ||
		pressure.ColdDispatches >= c.config.ColdDispatchThreshold ||
		pressure.SpeculativeStarted >= c.config.SpeculativeStartThreshold ||
		pressure.SpeculativeWon >= c.config.SpeculativeWinThreshold {
		return true
	}
	if queue.Depth > 0 && queue.OldestAge >= c.config.QueueAgeThreshold {
		return true
	}
	externalPressure := queue.Depth > 0 || pressure.CapacityRejects > 0 || pressure.TTFTMisses > 0 ||
		pressure.SpeculativeStarted > 0 || pressure.SpeculativeWon > 0 || pressure.ColdDispatches > 0
	if fleet.Warm > 0 && externalPressure && c.config.WarmSaturationThreshold > 0 &&
		float64(fleet.WarmSaturated)/float64(fleet.Warm) >= c.config.WarmSaturationThreshold {
		return true
	}
	return false
}

// targetWarm computes the Little's Law warm-provider target for a model, then
// applies the dwell guard so a transient demand dip cannot shrink the pool before
// MinDwell elapses (anti-flap).
func (c planningPass[A]) targetWarm(fleet FleetModel, pressure Pressure, queue QueuePressure, params Params, svc time.Duration, now time.Time) int {
	target := Target(c.targetInputs(fleet, pressure, queue), params, svc)
	if c.config.MinDwell > 0 && pressure.LastTarget > target && now.Sub(pressure.LastTargetChangedAt) < c.config.MinDwell {
		target = pressure.LastTarget
		if maxReachable := fleet.Warm + len(fleet.EligibleCold); target > maxReachable {
			target = maxReachable
		}
	}
	if floor := c.config.MinWarmByModel[fleet.Model]; floor > target {
		target = floor
		if maxReachable := fleet.Warm + len(fleet.EligibleCold); target > maxReachable {
			target = maxReachable
		}
	}
	// Dedicated pools (e.g. Gemma): when a dedicated build is under demand, warm the
	// ENTIRE eligible pool rather than demand-tracking it — this lifts idle dedicated
	// boxes into service and removes cold-start lag (a cold box's ~30s load makes it
	// un-routable on the request hot path, so proactive warming is the only way it
	// ever serves). Gated on demand for THIS build so we don't force-warm every
	// build a box advertises matching the family pattern — e.g. during an alias
	// migration where desired+previous Gemma builds are both catalog-allowed, only
	// the build actually receiving traffic gets the whole pool, not the stale one
	// (which would otherwise burn model slots/memory and evict the live build).
	// Bounded by warm+eligibleCold; the per-tick ramp still throttles the load rate.
	if c.bindings.FleetSnapshot != nil && c.bindings.IsDedicatedModel(fleet.Model) && c.hasDemandPressure(fleet, pressure, queue) {
		if whole := fleet.Warm + len(fleet.EligibleCold); whole > target {
			target = whole
		}
	}
	return target
}
