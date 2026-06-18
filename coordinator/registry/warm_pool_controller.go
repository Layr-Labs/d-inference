package registry

import (
	"context"
	"sort"
	"sync"
	"time"
)

// Service-time (E[S]) clamps for the Little's Law target. A near-zero or absurdly
// large per-request rate must not let the demand-to-concurrency conversion produce
// a runaway or zero target.
const (
	warmPoolMinServiceTime = 500 * time.Millisecond
	warmPoolMaxServiceTime = 2 * time.Minute
)

type warmPoolController struct {
	registry *Registry
	config   WarmPoolConfig
	state    *warmPoolState
	queueMu  syncQueuePressure
	tickMu   sync.Mutex
	triggerC chan struct{}
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
	RunningRequests    int
	WaitingRequests    int
	SpillArrivalRate   float64
	ServiceTime        time.Duration
	QualityConcurrency int
	DemandConcurrency  float64
}

type warmPoolModelSnapshot struct {
	model         string
	warm          int
	warmSaturated int
	// running / waiting are the in-flight load summed across warm providers'
	// backend slots for this model (the observable L in Little's Law).
	running int
	waiting int
	// soloDecodeTPS / prefillTPS / maxProviderConc are representative (median)
	// rates and the per-provider concurrency cap across providers serving the
	// model, used for quality concurrency and the E[S] service-time estimate.
	soloDecodeTPS   float64
	prefillTPS      float64
	maxProviderConc int
	eligibleCold    []warmPoolCandidate
}

type warmPoolCandidate struct {
	providerID string
	score      float64
}

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
	for _, snap := range snapshots {
		if c.registry.logger != nil {
			c.registry.logger.Info("warm_pool_tick",
				"model", snap.Model,
				"target_warm", snap.TargetWarm,
				"warm", snap.WarmProviders,
				"eligible_cold", snap.EligibleCold,
				"running", snap.RunningRequests,
				"waiting", snap.WaitingRequests,
				"queue_depth", snap.QueueDepth,
				"oldest_queue_age_ms", snap.OldestQueueAge.Milliseconds(),
				"spill_arrival_rate", snap.SpillArrivalRate,
				"service_time_ms", snap.ServiceTime.Milliseconds(),
				"quality_concurrency", snap.QualityConcurrency,
				"demand_concurrency", snap.DemandConcurrency,
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
	pressure := c.state.snapshot(now, stateWindow)
	queue := c.queueSnapshot(now, stateWindow)
	fleet := c.registry.warmPoolFleetSnapshot(now)

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
	sort.Strings(ordered)

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
	var out []WarmPoolSnapshot
	for _, model := range ordered {
		p := pressure[model]
		q := queue[model]
		f := fleet[model]
		svc := estimateServiceTime(f.prefillTPS, f.soloDecodeTPS, params)
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
		actions := make([]modelLoadAction, 0, need)
		for i := 0; i < need; i++ {
			actions = append(actions, modelLoadAction{providerID: f.eligibleCold[i].providerID, modelID: model})
		}
		if reserve != nil && !c.config.ObserveOnly {
			actions = reserve(actions, now)
		}
		loadsRemaining -= len(actions)
		c.state.rememberTarget(model, target, now)
		out = append(out, WarmPoolSnapshot{
			Model:              model,
			TargetWarm:         target,
			WarmProviders:      f.warm,
			EligibleCold:       len(f.eligibleCold),
			QueueDepth:         q.Depth,
			OldestQueueAge:     q.OldestAge,
			CapacityRejects:    p.capacityRejects,
			TTFTMisses:         p.ttftMisses,
			SpeculativeStarted: p.speculativeStarted,
			SpeculativeWon:     p.speculativeWon,
			ColdDispatches:     p.coldDispatches,
			LoadDurationEWMA:   p.loadDurationEWMA,
			ObserveOnly:        c.config.ObserveOnly,
			Actions:            actions,
			RunningRequests:    f.running,
			WaitingRequests:    f.waiting,
			SpillArrivalRate:   p.arrivalRateEWMA,
			ServiceTime:        svc,
			QualityConcurrency: qualityConcurrency(f.soloDecodeTPS, params.DecodeFloorTPS, params.LoadFactorK, f.maxProviderConc, params.FallbackQualityConcurrency),
			DemandConcurrency:  demandConcurrency(c.targetInputs(f, p, q), svc),
		})
	}
	return out
}

func (c *warmPoolController) reserveActions(actions []modelLoadAction, now time.Time) []modelLoadAction {
	return c.registry.reservePendingModelLoads(actions, now)
}

// targetParams snapshots the controller config into the pure warmTargetParams
// consumed by the Little's Law math in warm_pool_target.go.
func (c *warmPoolController) targetParams() warmTargetParams {
	return warmTargetParams{
		DecodeFloorTPS:             c.config.DecodeFloorTPS,
		LoadFactorK:                effectiveTPSLoadFactor,
		BurstBuffer:                c.config.BurstBuffer,
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
		Warm:             fleet.warm,
		EligibleCold:     len(fleet.eligibleCold),
		RunningRequests:  fleet.running,
		WaitingRequests:  fleet.waiting,
		QueueDepth:       queue.Depth,
		SpillArrivalRate: pressure.arrivalRateEWMA,
		SoloDecodeTPS:    fleet.soloDecodeTPS,
		PrefillTPS:       fleet.prefillTPS,
		MaxProviderConc:  fleet.maxProviderConc,
		DemandPressure:   c.hasDemandPressure(fleet, pressure, queue),
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

func (r *Registry) warmPoolFleetSnapshot(now time.Time) map[string]warmPoolModelSnapshot {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make(map[string]warmPoolModelSnapshot)
	// Per-model rate samples (from every eligible provider serving the model,
	// warm or warmable) collapsed to a representative median at the end.
	decodeSamples := make(map[string][]float64)
	prefillSamples := make(map[string][]float64)
	concSamples := make(map[string][]float64)
	for _, p := range r.providers {
		p.mu.Lock()
		models := make([]string, 0, len(p.Models))
		for _, m := range p.Models {
			if r.modelAllowedByCatalogLocked(m) {
				models = append(models, m.ID)
			}
		}
		for _, model := range models {
			warm := r.providerHasWarmModelLocked(p, model, now)
			if warm {
				s := out[model]
				s.model = model
				s.warm++
				running, waiting := warmPoolModelLoadLocked(p, model)
				s.running += running
				s.waiting += waiting
				if !p.hasConcurrencyHeadroomForModelLocked(model) || warmPoolBackendSlotBusyLocked(p) {
					s.warmSaturated++
				}
				out[model] = s
				decodeSamples[model] = append(decodeSamples[model], resolvedDecodeTPS(p))
				prefillSamples[model] = append(prefillSamples[model], resolvedPrefillTPS(p))
				concSamples[model] = append(concSamples[model], float64(p.maxConcurrencyForModelLocked(model)))
				continue
			}
			if candidate, ok := r.warmPoolCandidateLocked(p, model, now); ok {
				s := out[model]
				s.model = model
				s.eligibleCold = append(s.eligibleCold, candidate)
				out[model] = s
				decodeSamples[model] = append(decodeSamples[model], resolvedDecodeTPS(p))
				prefillSamples[model] = append(prefillSamples[model], resolvedPrefillTPS(p))
				concSamples[model] = append(concSamples[model], float64(p.maxConcurrencyForModelLocked(model)))
			}
		}
		p.mu.Unlock()
	}
	for model, s := range out {
		sort.Slice(s.eligibleCold, func(i, j int) bool { return s.eligibleCold[i].score > s.eligibleCold[j].score })
		s.soloDecodeTPS = medianFloat(decodeSamples[model])
		s.prefillTPS = medianFloat(prefillSamples[model])
		s.maxProviderConc = int(medianFloat(concSamples[model]))
		out[model] = s
	}
	return out
}

// warmPoolModelLoadLocked returns the in-flight (NumRunning) and provider-queued
// (NumWaiting) request counts for the model on this provider, read from the
// authoritative BackendCapacity slot. Caller must hold p.mu.
func warmPoolModelLoadLocked(p *Provider, model string) (running, waiting int) {
	if p.BackendCapacity == nil {
		return 0, 0
	}
	for _, slot := range p.BackendCapacity.Slots {
		if slot.Model == model {
			return slot.NumRunning, slot.NumWaiting
		}
	}
	return 0, 0
}

func (r *Registry) warmPoolCandidateLocked(p *Provider, model string, now time.Time) (warmPoolCandidate, bool) {
	if p.Status == StatusOffline || p.Status == StatusUntrusted || p.PrivateOnly {
		return warmPoolCandidate{}, false
	}
	if r.providerHasPendingLoad(p.ID) || r.dispatchLoadCooldownActiveLocked(p.ID, model, now) {
		return warmPoolCandidate{}, false
	}
	if p.pendingCount() != 0 || warmPoolBackendSlotBusyLocked(p) {
		return warmPoolCandidate{}, false
	}
	if p.SystemMetrics.ThermalState == "critical" {
		return warmPoolCandidate{}, false
	}
	if trustRank(p.TrustLevel) < trustRank(r.MinTrustLevel) || !p.RuntimeVerified || !r.providerSupportsPrivateTextLocked(p) {
		return warmPoolCandidate{}, false
	}
	if p.LastChallengeVerified.IsZero() || now.Sub(p.LastChallengeVerified) > challengeFreshnessMaxAge {
		return warmPoolCandidate{}, false
	}
	if !r.providerServesCatalogModelLocked(p, model) {
		return warmPoolCandidate{}, false
	}
	totalMemoryGB := float64(p.Hardware.MemoryGB)
	gpuActiveGB := 0.0
	if p.BackendCapacity != nil {
		if p.BackendCapacity.TotalMemoryGB > 0 {
			totalMemoryGB = p.BackendCapacity.TotalMemoryGB
		}
		gpuActiveGB = p.BackendCapacity.GPUMemoryActiveGB
	}
	if !modelFitsHardware(r.catalogMinRAMGbLocked(model), r.catalogSizeGBLocked(model), totalMemoryGB) {
		return warmPoolCandidate{}, false
	}
	// Live free-capacity gate (shared helper with the direct/planner paths): don't
	// pick a warm-pool target the provider already reports it cannot fit, or the
	// warm pool issues a load_model the provider rejects (failed warm + pending-load
	// cooldown) instead of choosing a truly loadable node (#390).
	if admit, reported := reportedFreeForLoadAdmits(r.catalogSizeGBLocked(model), backendFreeForLoadGB(p.BackendCapacity)); reported && !admit {
		return warmPoolCandidate{}, false
	}
	freeGB := totalMemoryGB - gpuActiveGB
	if freeGB < 0 {
		freeGB = 0
	}
	thermalPenalty := 0.0
	switch p.SystemMetrics.ThermalState {
	case "serious":
		thermalPenalty = 1000
	case "fair":
		thermalPenalty = 250
	}
	score := freeGB*100 + resolvedDecodeTPS(p)*10 - p.SystemMetrics.MemoryPressure*500 - p.SystemMetrics.CPUUsage*100 - thermalPenalty
	return warmPoolCandidate{providerID: p.ID, score: score}, true
}

func warmPoolBackendSlotBusyLocked(p *Provider) bool {
	if p.BackendCapacity == nil {
		return false
	}
	for _, slot := range p.BackendCapacity.Slots {
		if slot.NumRunning > 0 || slot.NumWaiting > 0 {
			return true
		}
	}
	return false
}

func (r *Registry) pendingModelLoadCount(now time.Time) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	count := 0
	for key, expiresAt := range r.pendingModelLoads {
		if now.After(expiresAt) {
			delete(r.pendingModelLoads, key)
			continue
		}
		count++
	}
	return count
}
