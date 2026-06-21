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
	RunningRequests    int
	WaitingRequests    int
	SpillArrivalRate   float64
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
	// coldIneligible / coldDisq tally cold (on-disk, not-warm) providers that
	// FAILED the warm-pool candidate gate, by reason — diagnostics for why
	// eligibleCold is smaller than the raw cold count.
	coldIneligible int
	coldDisq       map[warmColdReason]int
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
			Model:              model,
			TargetWarm:         target,
			WarmProviders:      f.warm,
			EligibleCold:       len(f.eligibleCold),
			ColdIneligible:     f.coldIneligible,
			ColdDisqualifiers:  warmColdReasonStrings(f.coldDisq),
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
				decodeTPS, prefillTPS := resolvedModelTPSLocked(p, model)
				decodeSamples[model] = append(decodeSamples[model], decodeTPS)
				prefillSamples[model] = append(prefillSamples[model], prefillTPS)
				concSamples[model] = append(concSamples[model], float64(p.maxConcurrencyForModelLocked(model)))
				continue
			}
			candidate, reason := r.warmPoolCandidateReasonLocked(p, model, now)
			s := out[model]
			s.model = model
			if reason == warmColdEligible {
				s.eligibleCold = append(s.eligibleCold, candidate)
				out[model] = s
				decodeTPS, prefillTPS := resolvedModelTPSLocked(p, model)
				decodeSamples[model] = append(decodeSamples[model], decodeTPS)
				prefillSamples[model] = append(prefillSamples[model], prefillTPS)
				concSamples[model] = append(concSamples[model], float64(p.maxConcurrencyForModelLocked(model)))
			} else {
				if s.coldDisq == nil {
					s.coldDisq = make(map[warmColdReason]int)
				}
				s.coldDisq[reason]++
				s.coldIneligible++
				out[model] = s
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

// warmColdReason labels why a cold (on-disk, not-warm) provider is or isn't an
// eligible warm-pool target. Empty ("") means eligible. Used to instrument why
// the eligible-cold set is smaller than the raw cold-provider count (e.g. a
// dedicated pool reporting many cold boxes but warming few) — counts only, no
// provider identities, so it is privacy-safe to log/expose.
type warmColdReason string

const (
	warmColdEligible       warmColdReason = ""
	warmColdOfflineUntrust warmColdReason = "offline_untrusted_private"
	warmColdPendingLoad    warmColdReason = "pending_load_or_cooldown"
	warmColdNotIdle        warmColdReason = "not_idle"
	warmColdThermal        warmColdReason = "thermal_critical"
	warmColdTrust          warmColdReason = "trust_or_runtime"
	warmColdStaleChallenge warmColdReason = "stale_challenge"
	warmColdNotServing     warmColdReason = "not_serving_catalog"
	warmColdDedicated      warmColdReason = "dedicated_excluded"
	warmColdTooLarge       warmColdReason = "model_too_large"
	warmColdNoFreeForLoad  warmColdReason = "no_free_for_load"
)

// warmColdReasonStrings converts a reason tally to a string-keyed map for
// logging / the snapshot. Returns nil for an empty tally.
func warmColdReasonStrings(in map[warmColdReason]int) map[string]int {
	if len(in) == 0 {
		return nil
	}
	out := make(map[string]int, len(in))
	for reason, n := range in {
		out[string(reason)] = n
	}
	return out
}

func (r *Registry) warmPoolCandidateLocked(p *Provider, model string, now time.Time) (warmPoolCandidate, bool) {
	c, reason := r.warmPoolCandidateReasonLocked(p, model, now)
	return c, reason == warmColdEligible
}

// warmPoolCandidateReasonLocked is warmPoolCandidateLocked with the
// disqualification reason exposed for instrumentation. Caller holds r.mu + p.mu.
func (r *Registry) warmPoolCandidateReasonLocked(p *Provider, model string, now time.Time) (warmPoolCandidate, warmColdReason) {
	if p.Status == StatusOffline || p.Status == StatusUntrusted || p.PrivateOnly {
		return warmPoolCandidate{}, warmColdOfflineUntrust
	}
	if r.providerHasPendingLoad(p.ID) || r.dispatchLoadCooldownActiveLocked(p.ID, model, now) {
		return warmPoolCandidate{}, warmColdPendingLoad
	}
	if p.pendingCount() != 0 || warmPoolBackendSlotBusyLocked(p) {
		return warmPoolCandidate{}, warmColdNotIdle
	}
	if p.SystemMetrics.ThermalState == "critical" {
		return warmPoolCandidate{}, warmColdThermal
	}
	if trustRank(p.TrustLevel) < trustRank(r.MinTrustLevel) || !p.RuntimeVerified || !r.providerSupportsPrivateTextLocked(p) {
		return warmPoolCandidate{}, warmColdTrust
	}
	if p.LastChallengeVerified.IsZero() || now.Sub(p.LastChallengeVerified) > challengeFreshnessMaxAge {
		return warmPoolCandidate{}, warmColdStaleChallenge
	}
	if !r.providerServesCatalogModelLocked(p, model) {
		return warmPoolCandidate{}, warmColdNotServing
	}
	// Don't pre-warm a dedicated-family model (e.g. Gemma 4) onto a non-dedicated
	// (mixed-catalog) box: routing will never send the model there, so the warm
	// would be wasted GPU memory and would mislead the demand calc into thinking
	// the model is already covered. Mirrors the routing/preflight gate.
	if r.providerExcludedByDedicatedRuleLocked(p, model) {
		return warmPoolCandidate{}, warmColdDedicated
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
		return warmPoolCandidate{}, warmColdTooLarge
	}
	// Live free-capacity gate (shared helper with the direct/planner paths): don't
	// pick a warm-pool target the provider already reports it cannot fit, or the
	// warm pool issues a load_model the provider rejects (failed warm + pending-load
	// cooldown) instead of choosing a truly loadable node (#390).
	if admit, reported := reportedFreeForLoadAdmits(r.catalogSizeGBLocked(model), backendFreeForLoadGB(p.BackendCapacity)); reported && !admit {
		return warmPoolCandidate{}, warmColdNoFreeForLoad
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
	return warmPoolCandidate{providerID: p.ID, score: score}, warmColdEligible
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
			delete(r.pendingModelLoadStarted, key)
			continue
		}
		count++
	}
	return count
}
