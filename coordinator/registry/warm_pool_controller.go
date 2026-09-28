package registry

import (
	"context"
	"sort"
	"time"
)

// Service-time (E[S]) clamps for the Little's Law target. A near-zero or absurdly
// large per-request rate must not let the demand-to-concurrency conversion produce
// a runaway or zero target.
const (
	warmPoolMinServiceTime = 500 * time.Millisecond
	warmPoolMaxServiceTime = 2 * time.Minute
)

func newWarmPoolController(r *Registry, cfg WarmPoolConfig) *warmPoolController {
	return &warmPoolController{
		registry: r,
		config:   cfg,
		state:    newWarmPoolState(),
		queueMu:  syncQueuePressure{models: make(map[string]warmPoolQueuePressure)},
		triggerC: make(chan struct{}, 1),
	}
}

func (r *Registry) ConfigureWarmPool(cfg WarmPoolConfig) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.warmPool == nil {
		r.warmPool = newWarmPoolController(r, cfg)
		return
	}
	r.warmPool.config = cfg
}

func (r *Registry) StartWarmPoolController(ctx context.Context, cfg WarmPoolConfig) func() {
	if !cfg.Enabled {
		return func() {}
	}
	r.ConfigureWarmPool(cfg)
	ctx, cancel := context.WithCancel(ctx)
	r.mu.RLock()
	controller := r.warmPool
	r.mu.RUnlock()
	go controller.run(ctx)
	return cancel
}

// RequestWarmPoolTrigger coalesces a hot-path warm-pool kick into the
// controller's single run goroutine. It never blocks callers: if a trigger is
// already queued or a tick is in progress, that pending pass is enough to observe
// the latest queue/capacity pressure.
func (r *Registry) RequestWarmPoolTrigger() bool {
	r.mu.RLock()
	controller := r.warmPool
	r.mu.RUnlock()
	if controller == nil || !controller.config.Enabled || controller.config.ObserveOnly {
		return false
	}
	select {
	case controller.triggerC <- struct{}{}:
		return true
	default:
		return false
	}
}

// TriggerWarmPool runs one active warm-pool planning pass immediately. It is a
// used by tests and administrative callers that need the resulting snapshots.
// Hot request paths should use RequestWarmPoolTrigger so bursts are coalesced.
func (r *Registry) TriggerWarmPool() []WarmPoolSnapshot {
	r.mu.RLock()
	controller := r.warmPool
	r.mu.RUnlock()
	if controller == nil || !controller.config.Enabled || controller.config.ObserveOnly {
		return nil
	}
	return controller.tick(time.Now())
}

// LatestWarmPoolSnapshots returns a copy of the most recent per-model warm-pool
// snapshots produced by the controller's last planning tick, along with the time
// they were produced. It is read-only and side-effect free (unlike
// TriggerWarmPool), so observability paths can consume the Little's Law
// diagnostics (DemandConcurrency, QualityConcurrency, WarmProviders, ...) safely.
// Returns nil when the controller is disabled or has not yet ticked.
func (r *Registry) LatestWarmPoolSnapshots() ([]WarmPoolSnapshot, time.Time) {
	r.mu.RLock()
	controller := r.warmPool
	r.mu.RUnlock()
	if controller == nil {
		return nil, time.Time{}
	}
	return controller.latestSnapshots()
}

func (c *warmPoolController) storeSnapshots(snaps []WarmPoolSnapshot, now time.Time) {
	cp := make([]WarmPoolSnapshot, len(snaps))
	copy(cp, snaps)
	c.lastMu.Lock()
	c.lastSnaps = cp
	c.lastSnapsAt = now
	c.lastMu.Unlock()
}

func (c *warmPoolController) latestSnapshots() ([]WarmPoolSnapshot, time.Time) {
	c.lastMu.RLock()
	defer c.lastMu.RUnlock()
	if len(c.lastSnaps) == 0 {
		return nil, c.lastSnapsAt
	}
	cp := make([]WarmPoolSnapshot, len(c.lastSnaps))
	copy(cp, c.lastSnaps)
	return cp, c.lastSnapsAt
}

func (c *warmPoolController) run(ctx context.Context) {
	interval := c.config.Interval
	if interval <= 0 {
		interval = 30 * time.Second
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-c.triggerC:
			c.tick(time.Now())
		case <-ticker.C:
			c.tick(time.Now())
		}
	}
}

func (c *warmPoolController) tick(now time.Time) []WarmPoolSnapshot {
	if c == nil || c.registry == nil {
		return nil
	}
	c.tickMu.Lock()
	defer c.tickMu.Unlock()
	snapshots := c.plan(now)
	c.storeSnapshots(snapshots, now)
	for _, snap := range snapshots {
		if c.registry.logger != nil {
			c.registry.logger.Info("warm_pool_tick",
				"model", snap.Model,
				"target_warm", snap.TargetWarm,
				"warm", snap.WarmProviders,
				"warm_saturated", snap.WarmSaturated,
				"warm_foreign_blocked", snap.WarmForeignBlocked,
				"occupancy_ramp", snap.OccupancyRamp,
				"headroom_providers", snap.HeadroomProviders,
				"eligible_cold", snap.EligibleCold,
				"running", snap.RunningRequests,
				"waiting", snap.WaitingRequests,
				"queue_depth", snap.QueueDepth,
				"oldest_queue_age_ms", snap.OldestQueueAge.Milliseconds(),
				"spill_arrival_rate", snap.SpillArrivalRate,
				"service_time_ms", snap.ServiceTime.Milliseconds(),
				"quality_concurrency", snap.QualityConcurrency,
				"demand_concurrency", snap.DemandConcurrency,
				"measured_prompt_tokens", snap.MeasuredPromptTokens,
				"measured_output_tokens", snap.MeasuredOutputTokens,
				"prompt_work_tps", snap.PromptWorkTPS,
				"generation_work_tps", snap.GenerationWorkTPS,
				"aggregate_decode_tps", snap.AggregateDecodeTPS,
				"work_providers", snap.WorkProviders,
				"capacity_rejects", snap.CapacityRejects,
				"ttft_misses", snap.TTFTMisses,
				"speculative_started", snap.SpeculativeStarted,
				"speculative_won", snap.SpeculativeWon,
				"cold_dispatches", snap.ColdDispatches,
				"actions", len(snap.Actions),
				"observe_only", snap.ObserveOnly,
			)
		}
		if snap.ObserveOnly || len(snap.Actions) == 0 {
			continue
		}
		c.registry.sendModelLoadActions(snap.Actions)
	}
	return snapshots
}

func (c *warmPoolController) plan(now time.Time) []WarmPoolSnapshot {
	if c.config.MaxLoadsPerTick == 0 || c.config.MaxGlobalPendingLoads == 0 {
		return c.planObserveOnly(now, nil)
	}
	return c.planObserveOnly(now, c.reserveActions)
}

func (c *warmPoolController) planObserveOnly(now time.Time, reserve func([]modelLoadAction, time.Time) []modelLoadAction) []WarmPoolSnapshot {
	stateWindow := c.config.Interval * 4
	if stateWindow < time.Minute {
		stateWindow = time.Minute
	}
	// Fold accumulated spill arrivals into the per-model EWMA before snapshotting
	// so the Little's Law target tracks demand. Gate folds at half the control
	// interval so coalesced hot-path trigger ticks don't spike the rate.
	c.state.foldArrivalRates(now, c.config.Interval/2, warmPoolArrivalEWMAAlpha)
	c.state.foldWorkRates(now, c.config.Interval/2)
	pressure := c.state.snapshot(now, stateWindow)
	queue := c.queueSnapshot(now, stateWindow)
	fleet := c.registry.warmPoolFleetSnapshot(now)

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
		occupancy[model] = f.running + f.waiting + queue[model].Depth
	}
	c.state.foldOccupancyRamp(occupancy, now, c.config.Interval, c.config.Interval/2, warmPoolArrivalEWMAAlpha)
	pressure = c.state.snapshot(now, stateWindow)

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

	perTickCeiling := c.config.perTickCeiling()
	loadsRemaining := perTickCeiling
	globalPendingRemaining := c.config.MaxGlobalPendingLoads - c.registry.pendingModelLoadCount(now)
	if globalPendingRemaining < loadsRemaining {
		loadsRemaining = globalPendingRemaining
	}
	if loadsRemaining < 0 {
		loadsRemaining = 0
	}

	params := c.targetParams()
	assigned := make(map[string]bool)
	var out []WarmPoolSnapshot
	for _, model := range ordered {
		p := pressure[model]
		q := queue[model]
		f := fleet[model]
		f.workProviders = measuredWorkProviders(f, p, now)
		// E[S] from the load-inclusive service rate (what a request actually
		// sees); quality concurrency below from the solo rate (the admission
		// cap's math). Falls back to the solo rate when no service samples
		// exist (both medians share the same provider set, so this only guards
		// the degenerate empty case).
		serviceTPS := f.serviceDecodeTPS
		if serviceTPS <= 0 {
			serviceTPS = f.soloDecodeTPS
		}
		serviceParams := measuredWarmServiceParams(params, p, now)
		svc := estimateServiceTime(f.prefillTPS, serviceTPS, serviceParams)
		if f.qualityConc > 0 && f.aggregateDecodeTPS > 0 {
			// Convert serial prompt work and measured aggregate generation work
			// into the request-concurrency units used by the existing target.
			// estimateServiceTime clamps work in Mac-time units BEFORE scaling;
			// clamping again here would divide long refused prompt work by the
			// decode width when warmTarget converts concurrency back to Macs.
			svc = estimateServiceTime(f.prefillTPS, f.aggregateDecodeTPS, serviceParams) * time.Duration(f.qualityConc)
		}
		target := c.targetWarm(f, p, q, params, svc, now)

		gap := target - f.warm
		if gap < 0 {
			gap = 0
		}
		// Demand-scaled, bounded per-tick ramp: close a fraction of the gap, at
		// least MaxLoadsPerTick, capped by the per-tick ceiling, then by what we
		// can actually warm (eligible cold) and the global pending budget.
		need := rampLoadsThisTick(gap, c.config.MaxLoadsPerTick, perTickCeiling, c.config.RampGapFraction)
		if need > len(f.eligibleCold) {
			need = len(f.eligibleCold)
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
		actions := allocateWarmPoolLoads(model, f.eligibleCold, need, assigned, now, activeReserve)
		loadsRemaining -= len(actions)
		c.state.rememberTarget(model, target, now)
		// Surface why cold boxes aren't warmable (counts only). For a dedicated pool
		// this explains a gap between the raw cold count and what we can actually warm.
		if f.coldIneligible > 0 && c.registry != nil && c.registry.logger != nil && c.registry.IsDedicatedModel(model) {
			c.registry.logger.Info("warm-pool cold-ineligible (dedicated)",
				"model", model,
				"warm", f.warm,
				"eligible_cold", len(f.eligibleCold),
				"cold_ineligible", f.coldIneligible,
				"reasons", warmColdReasonStrings(f.coldDisq),
			)
		}
		out = append(out, WarmPoolSnapshot{
			Model:                model,
			TargetWarm:           target,
			WarmProviders:        f.warm,
			EligibleCold:         len(f.eligibleCold),
			ColdIneligible:       f.coldIneligible,
			ColdDisqualifiers:    warmColdReasonStrings(f.coldDisq),
			QueueDepth:           q.Depth,
			OldestQueueAge:       q.OldestAge,
			CapacityRejects:      p.capacityRejects,
			TTFTMisses:           p.ttftMisses,
			SpeculativeStarted:   p.speculativeStarted,
			SpeculativeWon:       p.speculativeWon,
			ColdDispatches:       p.coldDispatches,
			LoadDurationEWMA:     p.loadDurationEWMA,
			ObserveOnly:          c.config.ObserveOnly,
			Actions:              actions,
			RunningRequests:      f.running,
			WaitingRequests:      f.waiting,
			WarmSaturated:        f.warmSaturated,
			WarmForeignBlocked:   f.warmForeignBlocked,
			OccupancyRamp:        p.occupancyRampEWMA,
			HeadroomProviders:    headroomProviders(c.targetInputs(f, p, q), params, warmPoolQualityConcurrency(f, params)),
			SpillArrivalRate:     p.arrivalRateEWMA,
			ServiceTime:          svc,
			QualityConcurrency:   warmPoolQualityConcurrency(f, params),
			DemandConcurrency:    demandConcurrency(c.targetInputs(f, p, q), svc),
			MeasuredPromptTokens: p.promptWork.tokens,
			MeasuredOutputTokens: p.outputWork.tokens,
			PromptWorkTPS:        p.promptWorkRate,
			GenerationWorkTPS:    p.outputWorkRate,
			AggregateDecodeTPS:   f.aggregateDecodeTPS,
			WorkProviders:        f.workProviders,
		})
	}
	return out
}

// targetParams snapshots the controller config into the pure warmTargetParams
// consumed by the Little's Law math in warm_pool_target.go.
func (c *warmPoolController) targetParams() warmTargetParams {
	return warmTargetParams{
		DecodeFloorTPS:             c.config.DecodeFloorTPS,
		LoadFactorK:                effectiveTPSLoadFactor,
		BurstBuffer:                c.config.BurstBuffer,
		HeadroomProviders:          c.config.HeadroomProviders,
		HeadroomEnabledParams:      c.config.HeadroomEnabled,
		HeadroomMaxProviders:       c.config.HeadroomMaxProviders,
		HeadroomLoadWindows:        c.config.HeadroomLoadWindows,
		FallbackQualityConcurrency: c.config.FallbackQualityConcurrency,
		AssumedPromptTokens:        c.config.AssumedPromptTokens,
		AssumedCompletionTokens:    c.config.AssumedCompletionTokens,
		MinServiceTime:             warmPoolMinServiceTime,
		MaxServiceTime:             warmPoolMaxServiceTime,
	}
}

// targetInputs assembles the measured per-model inputs for the Little's Law
// target from the fleet, pressure, and queue snapshots.
func (c *warmPoolController) targetInputs(fleet warmPoolModelSnapshot, pressure warmPoolPressureBucket, queue warmPoolQueuePressure) warmTargetInputs {
	return warmTargetInputs{
		Model:              fleet.model,
		Warm:               fleet.warm,
		WarmSaturated:      fleet.warmSaturated,
		WarmForeignBlocked: fleet.warmForeignBlocked,
		EligibleCold:       len(fleet.eligibleCold),
		RunningRequests:    fleet.running,
		WaitingRequests:    fleet.waiting,
		QueueDepth:         queue.Depth,
		SpillArrivalRate:   pressure.arrivalRateEWMA,
		OccupancyRamp:      pressure.occupancyRampEWMA,
		SoloDecodeTPS:      fleet.soloDecodeTPS,
		PrefillTPS:         fleet.prefillTPS,
		MaxProviderConc:    fleet.maxProviderConc,
		QualityConcurrency: fleet.qualityConc,
		WorkProviders:      fleet.workProviders,
		DemandPressure:     c.hasDemandPressure(fleet, pressure, queue),
	}
}

// hasDemandPressure reports whether any pressure signal crossed its threshold
// this window. It consumes ALL signals fed to the controller — capacity rejects,
// TTFT misses, cold dispatches, speculative starts/wins (now including the W3
// preflight-fed near-misses), an aged coordinator queue, and a saturated warm set
// under any external pressure. With no demand pressure the pool is left as-is.
func (c *warmPoolController) hasDemandPressure(fleet warmPoolModelSnapshot, pressure warmPoolPressureBucket, queue warmPoolQueuePressure) bool {
	if pressure.capacityRejects >= c.config.CapacityRejectThreshold ||
		pressure.ttftMisses >= c.config.TTFTMissThreshold ||
		pressure.coldDispatches >= c.config.ColdDispatchThreshold ||
		pressure.speculativeStarted >= c.config.SpeculativeStartThreshold ||
		pressure.speculativeWon >= c.config.SpeculativeWinThreshold {
		return true
	}
	if queue.Depth > 0 && queue.OldestAge >= c.config.QueueAgeThreshold {
		return true
	}
	externalPressure := queue.Depth > 0 || pressure.capacityRejects > 0 || pressure.ttftMisses > 0 ||
		pressure.speculativeStarted > 0 || pressure.speculativeWon > 0 || pressure.coldDispatches > 0
	if fleet.warm > 0 && externalPressure && c.config.WarmSaturationThreshold > 0 &&
		float64(fleet.warmSaturated)/float64(fleet.warm) >= c.config.WarmSaturationThreshold {
		return true
	}
	return false
}

// targetWarm computes the Little's Law warm-provider target for a model, then
// applies the dwell guard so a transient demand dip cannot shrink the pool before
// MinDwell elapses (anti-flap).
func (c *warmPoolController) targetWarm(fleet warmPoolModelSnapshot, pressure warmPoolPressureBucket, queue warmPoolQueuePressure, params warmTargetParams, svc time.Duration, now time.Time) int {
	target := warmTarget(c.targetInputs(fleet, pressure, queue), params, svc)
	if c.config.MinDwell > 0 && pressure.lastTarget > target && now.Sub(pressure.lastTargetChangedAt) < c.config.MinDwell {
		target = pressure.lastTarget
		if maxReachable := fleet.warm + len(fleet.eligibleCold); target > maxReachable {
			target = maxReachable
		}
	}
	if floor := c.config.MinWarmByModel[fleet.model]; floor > target {
		target = floor
		if maxReachable := fleet.warm + len(fleet.eligibleCold); target > maxReachable {
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
	if c.registry != nil && c.registry.IsDedicatedModel(fleet.model) && c.hasDemandPressure(fleet, pressure, queue) {
		if whole := fleet.warm + len(fleet.eligibleCold); whole > target {
			target = whole
		}
	}
	return target
}

func (c *warmPoolController) recordQueuePressure(model string, depth int, oldestAge time.Duration, now time.Time) {
	c.queueMu.mu.Lock()
	defer c.queueMu.mu.Unlock()
	if depth <= 0 {
		delete(c.queueMu.models, model)
		return
	}
	if oldestAge < 0 {
		oldestAge = 0
	}
	c.queueMu.models[model] = warmPoolQueuePressure{Depth: depth, OldestAge: oldestAge, UpdatedAt: now}
}

func (c *warmPoolController) queueSnapshot(now time.Time, recentWindow time.Duration) map[string]warmPoolQueuePressure {
	c.queueMu.mu.Lock()
	defer c.queueMu.mu.Unlock()
	out := make(map[string]warmPoolQueuePressure, len(c.queueMu.models))
	for model, p := range c.queueMu.models {
		if !p.UpdatedAt.IsZero() && now.Sub(p.UpdatedAt) > recentWindow {
			delete(c.queueMu.models, model)
			continue
		}
		out[model] = p
	}
	return out
}
