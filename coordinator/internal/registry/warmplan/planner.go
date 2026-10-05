package warmplan

import (
	"sort"
	"time"
)

func warmPoolQualityConcurrency(f Fleet, p TargetParams) int {
	if f.QualityConc > 0 {
		return f.QualityConc
	}
	return QualityConcurrency(f.SoloDecodeTPS, p.DecodeFloorTPS, p.LoadFactorK, f.MaxProviderConc, p.FallbackQualityConcurrency)
}

func (c *Controller[A]) plan(now time.Time) []Snapshot[A] {
	if !c.config.ActivePlanner() {
		return c.PlanObserveOnly(now, nil)
	}
	return c.PlanObserveOnly(now, c.deps.Reserve)
}

func (c *Controller[A]) PlanObserveOnly(now time.Time, reserve func([]A, time.Time) []A) []Snapshot[A] {
	stateWindow := c.config.Interval * 4
	if stateWindow < time.Minute {
		stateWindow = time.Minute
	}
	// Fold accumulated spill arrivals into the per-model EWMA before snapshotting
	// so the Little's Law target tracks demand. Gate folds at half the control
	// interval so coalesced hot-path trigger ticks don't spike the rate.
	c.state.FoldArrivalRates(now, c.config.Interval/2, WarmPoolArrivalEWMAAlpha)
	c.state.FoldWorkRates(now, c.config.Interval/2)
	pressure := c.state.Snapshot(now, stateWindow)
	queue := c.queueSnapshot(now, stateWindow)
	// Reap before collecting candidates: an expired reservation must free both
	// its provider and the global budget for this same planning pass.
	pendingLoads := c.deps.PendingLoads(now)
	fleet := c.deps.Fleet(now)

	// Fold this tick's occupancy into each model's demand-growth EWMA, which the
	// derived proactive headroom floor is sized from. Done AFTER the fleet
	// snapshot (it is the source of running/waiting) but BEFORE targets are
	// computed, so the floor sees the current ramp. Re-snapshot the pressure
	// buckets afterwards to pick up the folded value.
	//
	// Same interval gate as foldArrivalRates, plus elapsed-time normalization:
	// the ramp is slots per CONTROL INTERVAL, and coalesced hot-path triggers make
	// planning passes irregular, so a raw per-pass delta would understate growth
	// during exactly the bursts this floor exists to absorb.
	occupancy := make(map[string]int, len(fleet))
	for model, f := range fleet {
		occupancy[model] = f.Running + f.Waiting + queue[model].Depth
	}
	c.state.FoldOccupancyRamp(occupancy, now, c.config.Interval, c.config.Interval/2, WarmPoolArrivalEWMAAlpha)
	pressure = c.state.Snapshot(now, stateWindow)

	models := make(map[string]struct{})
	for model := range pressure {
		models[model] = struct{}{}
	}
	for model := range queue {
		models[model] = struct{}{}
	}
	for model := range fleet {
		models[model] = struct{}{}
	}

	ordered := make([]string, 0, len(models))
	for model := range models {
		ordered = append(ordered, model)
	}
	sort.Slice(ordered, func(i, j int) bool {
		left, right := ordered[i], ordered[j]
		lp := c.hasDemandPressure(fleet[left], pressure[left], queue[left])
		rp := c.hasDemandPressure(fleet[right], pressure[right], queue[right])
		if lp != rp {
			return lp
		}
		return left < right
	})

	perTickCeiling := c.config.PerTickCeiling()
	loadsRemaining := perTickCeiling
	globalPendingRemaining := c.config.MaxGlobalPendingLoads - pendingLoads
	if globalPendingRemaining < loadsRemaining {
		loadsRemaining = globalPendingRemaining
	}
	if loadsRemaining < 0 {
		loadsRemaining = 0
	}

	params := c.TargetParams()
	assigned := make(map[string]bool)
	var out []Snapshot[A]
	for _, model := range ordered {
		p := pressure[model]
		q := queue[model]
		f := fleet[model]
		f.WorkProviders = MeasuredWorkProviders(f, p, now)
		// E[S] from the load-inclusive service rate (what a request actually
		// sees); quality concurrency below from the solo rate (the admission
		// cap's math). Falls back to the solo rate when no service samples
		// exist (both medians share the same provider set, so this only guards
		// the degenerate empty case).
		serviceTPS := f.ServiceDecodeTPS
		if serviceTPS <= 0 {
			serviceTPS = f.SoloDecodeTPS
		}
		serviceParams := MeasuredWarmServiceParams(params, p, now)
		svc := EstimateServiceTime(f.PrefillTPS, serviceTPS, serviceParams)
		if f.QualityConc > 0 && f.AggregateDecodeTPS > 0 {
			// Convert serial prompt work and measured aggregate generation work
			// into the request-concurrency units used by the existing target.
			// estimateServiceTime clamps work in Mac-time units BEFORE scaling;
			// clamping again here would divide long refused prompt work by the
			// decode width when warmTarget converts concurrency back to Macs.
			svc = EstimateServiceTime(f.PrefillTPS, f.AggregateDecodeTPS, serviceParams) * time.Duration(f.QualityConc)
		}
		target := c.TargetWarm(f, p, q, params, svc, now)

		gap := target - f.Warm
		if gap < 0 {
			gap = 0
		}
		// Demand-scaled, bounded per-tick ramp: close a fraction of the gap, at
		// least MaxLoadsPerTick, capped by the per-tick ceiling, then by what we
		// can actually warm (eligible cold) and the global pending budget.
		need := RampLoadsThisTick(gap, c.config.MaxLoadsPerTick, perTickCeiling, c.config.RampGapFraction)
		if need > len(f.EligibleCold) {
			need = len(f.EligibleCold)
		}
		if need > loadsRemaining {
			need = loadsRemaining
		}
		if need < 0 {
			need = 0
		}
		activeReserve := reserve
		if c.config.ObserveOnly {
			activeReserve = nil
		}
		actions := c.allocateLoads(model, f.EligibleCold, need, assigned, now, activeReserve)
		loadsRemaining -= len(actions)
		c.state.RememberTarget(model, target, now)
		// Surface why cold boxes aren't warmable (counts only). For a dedicated pool
		// this explains a gap between the raw cold count and what we can actually warm.
		if f.ColdIneligible > 0 && c.deps.Dedicated != nil && c.deps.Logger != nil && c.deps.Dedicated(model) {
			c.deps.Logger.Info("warm-pool cold-ineligible (dedicated)",
				"model", model,
				"warm", f.Warm,
				"eligible_cold", len(f.EligibleCold),
				"cold_ineligible", f.ColdIneligible,
				"reasons", ColdReasonStrings(f.ColdDisq),
			)
		}
		out = append(out, Snapshot[A]{
			Model:                model,
			TargetWarm:           target,
			WarmProviders:        f.Warm,
			EligibleCold:         len(f.EligibleCold),
			ColdIneligible:       f.ColdIneligible,
			ColdDisqualifiers:    ColdReasonStrings(f.ColdDisq),
			QueueDepth:           q.Depth,
			OldestQueueAge:       q.OldestAge,
			CapacityRejects:      p.CapacityRejects,
			TTFTMisses:           p.TtftMisses,
			SpeculativeStarted:   p.SpeculativeStarted,
			SpeculativeWon:       p.SpeculativeWon,
			ColdDispatches:       p.ColdDispatches,
			LoadDurationEWMA:     p.LoadDurationEWMA,
			ObserveOnly:          !c.config.ActivePlanner(),
			Actions:              actions,
			RunningRequests:      f.Running,
			WaitingRequests:      f.Waiting,
			WarmSaturated:        f.WarmSaturated,
			WarmForeignBlocked:   f.WarmForeignBlocked,
			OccupancyRamp:        p.OccupancyRampEWMA,
			HeadroomProviders:    HeadroomProviders(c.targetInputs(f, p, q), params, warmPoolQualityConcurrency(f, params)),
			SpillArrivalRate:     p.ArrivalRateEWMA,
			ServiceTime:          svc,
			QualityConcurrency:   warmPoolQualityConcurrency(f, params),
			DemandConcurrency:    DemandConcurrency(c.targetInputs(f, p, q), svc),
			MeasuredPromptTokens: p.PromptWork.Tokens,
			MeasuredOutputTokens: p.OutputWork.Tokens,
			PromptWorkTPS:        p.PromptWorkRate,
			GenerationWorkTPS:    p.OutputWorkRate,
			AggregateDecodeTPS:   f.AggregateDecodeTPS,
			WorkProviders:        f.WorkProviders,
		})
	}
	return out
}

// targetParams snapshots the controller config into the pure warmTargetParams
// consumed by the Little's Law math in warm_pool_target.go.
func (c *Controller[A]) TargetParams() TargetParams {
	return TargetParams{
		DecodeFloorTPS:             c.config.DecodeFloorTPS,
		LoadFactorK:                DecodeLoadFactor,
		BurstBuffer:                c.config.BurstBuffer,
		HeadroomProviders:          c.config.HeadroomProviders,
		HeadroomEnabledParams:      c.config.HeadroomEnabled,
		HeadroomMaxProviders:       c.config.HeadroomMaxProviders,
		HeadroomLoadWindows:        c.config.HeadroomLoadWindows,
		FallbackQualityConcurrency: c.config.FallbackQualityConcurrency,
		AssumedPromptTokens:        c.config.AssumedPromptTokens,
		AssumedCompletionTokens:    c.config.AssumedCompletionTokens,
		MinServiceTime:             WarmPoolMinServiceTime,
		MaxServiceTime:             WarmPoolMaxServiceTime,
	}
}

// targetInputs assembles the measured per-model inputs for the Little's Law
// target from the fleet, pressure, and queue snapshots.
func (c *Controller[A]) targetInputs(fleet Fleet, pressure Pressure, queue QueuePressure) TargetInputs {
	return TargetInputs{
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
		QualityConcurrency: fleet.QualityConc,
		WorkProviders:      fleet.WorkProviders,
		DemandPressure:     c.hasDemandPressure(fleet, pressure, queue),
	}
}

// hasDemandPressure reports whether any pressure signal crossed its threshold
// this window. It consumes ALL signals fed to the controller — capacity rejects,
// TTFT misses, cold dispatches, speculative starts/wins (now including the W3
// preflight-fed near-misses), an aged coordinator queue, and a saturated warm set
// under any external pressure. With no demand pressure the pool is left as-is.
func (c *Controller[A]) hasDemandPressure(fleet Fleet, pressure Pressure, queue QueuePressure) bool {
	if pressure.CapacityRejects >= c.config.CapacityRejectThreshold ||
		pressure.TtftMisses >= c.config.TTFTMissThreshold ||
		pressure.ColdDispatches >= c.config.ColdDispatchThreshold ||
		pressure.SpeculativeStarted >= c.config.SpeculativeStartThreshold ||
		pressure.SpeculativeWon >= c.config.SpeculativeWinThreshold {
		return true
	}
	if queue.Depth > 0 && queue.OldestAge >= c.config.QueueAgeThreshold {
		return true
	}
	externalPressure := queue.Depth > 0 || pressure.CapacityRejects > 0 || pressure.TtftMisses > 0 ||
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
func (c *Controller[A]) TargetWarm(fleet Fleet, pressure Pressure, queue QueuePressure, params TargetParams, svc time.Duration, now time.Time) int {
	target := WarmTarget(c.targetInputs(fleet, pressure, queue), params, svc)
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
	if c.deps.Dedicated != nil && c.deps.Dedicated(fleet.Model) && c.hasDemandPressure(fleet, pressure, queue) {
		if whole := fleet.Warm + len(fleet.EligibleCold); whole > target {
			target = whole
		}
	}
	return target
}

func (c *Controller[A]) allocateLoads(model string, candidates []Candidate, need int, assigned map[string]bool, now time.Time, reserve func([]A, time.Time) []A) []A {
	var actions []A
	for _, candidate := range candidates {
		if len(actions) >= need {
			break
		}
		if assigned[candidate.ProviderID] {
			continue
		}
		action := c.deps.NewAction(candidate.ProviderID, model)
		if reserve != nil {
			reserved := reserve([]A{action}, now)
			if len(reserved) == 0 {
				continue
			}
			action = reserved[0]
		}
		assigned[candidate.ProviderID] = true
		actions = append(actions, action)
	}
	return actions
}
