package warmpool

import (
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/throughput"
)

func (c *Controller[A]) Plan(now time.Time) []Snapshot[A] {
	if c.configuration().MaxLoadsPerTick == 0 || c.configuration().MaxGlobalPendingLoads == 0 {
		return c.PlanObserveOnly(now, nil)
	}
	return c.PlanObserveOnly(now, c.reserveActions)
}

func (c *Controller[A]) PlanObserveOnly(now time.Time, reserve func([]A, time.Time) []A) []Snapshot[A] {
	stateWindow := c.configuration().Interval * 4
	if stateWindow < time.Minute {
		stateWindow = time.Minute
	}
	// Fold accumulated spill arrivals into the per-model EWMA before snapshotting
	// so the Little's Law target tracks demand. Gate folds at half the control
	// interval so coalesced hot-path trigger ticks don't spike the rate.
	c.state.FoldArrivalRates(now, c.configuration().Interval/2, ArrivalEWMAAlpha)
	pressure := c.state.Snapshot(now, stateWindow)
	queue := c.queueSnapshot(now, stateWindow)
	fleet := c.bindings.FleetSnapshot(now)

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
	c.state.FoldOccupancyRamp(occupancy, now, c.configuration().Interval, c.configuration().Interval/2, ArrivalEWMAAlpha)
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

	perTickCeiling := c.configuration().PerTickCeiling()
	loadsRemaining := perTickCeiling
	globalPendingRemaining := c.configuration().MaxGlobalPendingLoads - c.bindings.PendingCount(now)
	if globalPendingRemaining < loadsRemaining {
		loadsRemaining = globalPendingRemaining
	}
	if loadsRemaining < 0 {
		loadsRemaining = 0
	}

	params := c.TargetParams()
	var out []Snapshot[A]
	for _, model := range ordered {
		p := pressure[model]
		q := queue[model]
		f := fleet[model]
		// E[S] from the load-inclusive service rate (what a request actually
		// sees); quality concurrency below from the solo rate (the admission
		// cap's math). Falls back to the solo rate when no service samples
		// exist (both medians share the same provider set, so this only guards
		// the degenerate empty case).
		serviceTPS := f.ServiceDecodeTPS
		if serviceTPS <= 0 {
			serviceTPS = f.SoloDecodeTPS
		}
		svc := ServiceTime(f.PrefillTPS, serviceTPS, params)
		target := c.TargetWarm(f, p, q, params, svc, now)

		gap := target - f.Warm
		if gap < 0 {
			gap = 0
		}
		// Demand-scaled, bounded per-tick ramp: close a fraction of the gap, at
		// least MaxLoadsPerTick, capped by the per-tick ceiling, then by what we
		// can actually warm (eligible cold) and the global pending budget.
		need := LoadsThisTick(gap, c.configuration().MaxLoadsPerTick, perTickCeiling, c.configuration().RampGapFraction)
		if need > len(f.EligibleCold) {
			need = len(f.EligibleCold)
		}
		if need > loadsRemaining {
			need = loadsRemaining
		}
		if need < 0 {
			need = 0
		}
		actions := make([]A, 0, need)
		for i := 0; i < need; i++ {
			actions = append(actions, c.bindings.Action(f.EligibleCold[i].ProviderID, model))
		}
		if reserve != nil && !c.configuration().ObserveOnly {
			actions = reserve(actions, now)
		}
		loadsRemaining -= len(actions)
		c.state.RememberTarget(model, target, now)
		// Surface why cold boxes aren't warmable (counts only). For a dedicated pool
		// this explains a gap between the raw cold count and what we can actually warm.
		if f.ColdIneligible > 0 && c.bindings.FleetSnapshot != nil && c.logger() != nil && c.bindings.IsDedicatedModel(model) {
			c.logger().Info("warm-pool cold-ineligible (dedicated)",
				"model", model,
				"warm", f.Warm,
				"eligible_cold", len(f.EligibleCold),
				"cold_ineligible", f.ColdIneligible,
				"reasons", ColdReasonStrings(f.ColdDisqualifiers),
			)
		}
		out = append(out, Snapshot[A]{
			Model:              model,
			TargetWarm:         target,
			WarmProviders:      f.Warm,
			EligibleCold:       len(f.EligibleCold),
			ColdIneligible:     f.ColdIneligible,
			ColdDisqualifiers:  ColdReasonStrings(f.ColdDisqualifiers),
			QueueDepth:         q.Depth,
			OldestQueueAge:     q.OldestAge,
			CapacityRejects:    p.CapacityRejects,
			TTFTMisses:         p.TTFTMisses,
			SpeculativeStarted: p.SpeculativeStarted,
			SpeculativeWon:     p.SpeculativeWon,
			ColdDispatches:     p.ColdDispatches,
			LoadDurationEWMA:   p.LoadDurationEWMA,
			ObserveOnly:        c.configuration().ObserveOnly,
			Actions:            actions,
			RunningRequests:    f.Running,
			WaitingRequests:    f.Waiting,
			WarmSaturated:      f.WarmSaturated,
			WarmForeignBlocked: f.WarmForeignBlocked,
			OccupancyRamp:      p.OccupancyRampEWMA,
			HeadroomProviders:  HeadroomProviders(c.targetInputs(f, p, q), params, throughput.QualityConcurrency(f.SoloDecodeTPS, params.DecodeFloorTPS, params.LoadFactorK, f.MaxProviderConc, params.FallbackQualityConcurrency)),
			SpillArrivalRate:   p.ArrivalRateEWMA,
			ServiceTime:        svc,
			QualityConcurrency: throughput.QualityConcurrency(f.SoloDecodeTPS, params.DecodeFloorTPS, params.LoadFactorK, f.MaxProviderConc, params.FallbackQualityConcurrency),
			DemandConcurrency:  DemandConcurrency(c.targetInputs(f, p, q), svc),
		})
	}
	return out
}

func (c *Controller[A]) reserveActions(actions []A, now time.Time) []A {
	return c.bindings.Reserve(actions, now)
}
