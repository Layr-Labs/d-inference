package registry

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
)

func newWarmPoolController(r *Registry, cfg warmplan.Config) *warmPoolController {
	c := &warmPoolController{
		registry: r,
		config:   cfg,
		state:    warmplan.NewState(),
		triggerC: make(chan struct{}, 1),
	}
	deps := warmplan.Dependencies[ModelLoadAction]{
		Config: cfg, State: c.state, Wakeups: c.triggerC,
		Fleet: r.warmPoolFleetSnapshot, PendingLoads: r.pendingModelLoadCount,
		Reserve: c.reserveActions, Send: r.sendModelLoadActions,
		NewAction: func(provider, model string) ModelLoadAction {
			return ModelLoadAction{ProviderID: provider, ModelID: model}
		},
		Dedicated: r.IsDedicatedModel, Logger: r.logger,
	}
	if r.warmPlanningFactory != nil {
		c.runtime = r.warmPlanningFactory(deps)
	} else {
		c.runtime = warmplan.NewController(deps)
	}
	return c
}

func (r *Registry) ConfigureWarmPool(cfg warmplan.Config) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.warmPool == nil {
		r.warmPool = newWarmPoolController(r, cfg)
		return
	}
	r.warmPool.config = cfg
	r.warmPool.runtime.Configure(cfg)
}

func (r *Registry) StartWarmPoolController(ctx context.Context, cfg warmplan.Config) func() {
	// Keep operator floors available to Autopilot even when legacy warming is off.
	r.ConfigureWarmPool(cfg)
	if !cfg.Enabled {
		return func() {}
	}
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
	active := controller != nil && controller.config.ActivePlanner()
	r.mu.RUnlock()
	if !active {
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
	active := controller != nil && controller.config.ActivePlanner()
	r.mu.RUnlock()
	if !active {
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

func (c *warmPoolController) latestSnapshots() ([]WarmPoolSnapshot, time.Time) {
	return c.runtime.LatestSnapshots()
}

func (c *warmPoolController) run(ctx context.Context) { c.runtime.Run(ctx) }

func (c *warmPoolController) tick(now time.Time) []WarmPoolSnapshot { return c.runtime.Tick(now) }

func (c *warmPoolController) targetParams() warmplan.TargetParams { return c.runtime.TargetParams() }

func (c *warmPoolController) recordQueuePressure(model string, depth int, age time.Duration, now time.Time) {
	c.runtime.RecordQueuePressure(model, depth, age, now)
}
