package registry

import (
	"context"
	"math"
	"sort"
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
}

type warmPoolModelSnapshot struct {
	model         string
	warm          int
	warmSaturated int
	eligibleCold  []warmPoolCandidate
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
				"queue_depth", snap.QueueDepth,
				"oldest_queue_age_ms", snap.OldestQueueAge.Milliseconds(),
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

	loadsRemaining := c.config.MaxLoadsPerTick
	if loadsRemaining < 0 {
		loadsRemaining = 0
	}
	globalPendingRemaining := c.config.MaxGlobalPendingLoads - c.registry.pendingModelLoadCount(now)
	if globalPendingRemaining < loadsRemaining {
		loadsRemaining = globalPendingRemaining
	}
	if loadsRemaining < 0 {
		loadsRemaining = 0
	}

	var out []WarmPoolSnapshot
	for _, model := range ordered {
		p := pressure[model]
		q := queue[model]
		f := fleet[model]
		target := c.targetWarm(f, p, q, now)
		need := target - f.warm
		if need < 0 {
			need = 0
		}
		if need > len(f.eligibleCold) {
			need = len(f.eligibleCold)
		}
		if need > loadsRemaining {
			need = loadsRemaining
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
		})
	}
	return out
}

func (c *warmPoolController) reserveActions(actions []modelLoadAction, now time.Time) []modelLoadAction {
	return c.registry.reservePendingModelLoads(actions, now)
}

func (c *warmPoolController) targetWarm(fleet warmPoolModelSnapshot, pressure warmPoolPressureBucket, queue warmPoolQueuePressure, now time.Time) int {
	target := fleet.warm
	add := 0
	if queue.Depth > 0 && queue.OldestAge >= c.config.QueueAgeThreshold {
		add++
		if queue.Depth > 1 {
			add += int(math.Ceil(float64(queue.Depth-1) / 4.0))
		}
	}
	if pressure.capacityRejects >= c.config.CapacityRejectThreshold {
		add++
	}
	if pressure.ttftMisses >= c.config.TTFTMissThreshold {
		add++
	}
	if pressure.speculativeStarted >= c.config.SpeculativeStartThreshold {
		add++
	}
	if pressure.speculativeWon >= c.config.SpeculativeWinThreshold {
		add++
	}
	if pressure.coldDispatches >= c.config.ColdDispatchThreshold {
		add++
	}
	if pressure.loadDurationEWMA >= c.config.LoadDurationThreshold && pressure.coldDispatches > 0 {
		add++
	}
	externalPressure := queue.Depth > 0 || pressure.capacityRejects > 0 || pressure.ttftMisses > 0 || pressure.speculativeStarted > 0 || pressure.speculativeWon > 0 || pressure.coldDispatches > 0
	if fleet.warm > 0 && externalPressure && float64(fleet.warmSaturated)/float64(fleet.warm) >= c.config.WarmSaturationThreshold {
		add++
	}
	target += add
	if target < 0 {
		target = 0
	}
	if target > fleet.warm+len(fleet.eligibleCold) {
		target = fleet.warm + len(fleet.eligibleCold)
	}
	if c.config.MinDwell > 0 && pressure.lastTarget > target && now.Sub(pressure.lastTargetChangedAt) < c.config.MinDwell {
		target = pressure.lastTarget
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
				if !p.hasConcurrencyHeadroomForModelLocked(model) || warmPoolBackendSlotBusyLocked(p) {
					s.warmSaturated++
				}
				out[model] = s
				continue
			}
			if candidate, ok := r.warmPoolCandidateLocked(p, model, now); ok {
				s := out[model]
				s.model = model
				s.eligibleCold = append(s.eligibleCold, candidate)
				out[model] = s
			}
		}
		p.mu.Unlock()
	}
	for model, s := range out {
		sort.Slice(s.eligibleCold, func(i, j int) bool { return s.eligibleCold[i].score > s.eligibleCold[j].score })
		out[model] = s
	}
	return out
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
