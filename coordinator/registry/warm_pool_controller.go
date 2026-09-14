package registry

import (
	"context"
	"log/slog"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/warmpool"
)

type warmPoolController = warmpool.Controller[modelLoadAction]
type WarmPoolSnapshot = warmpool.Snapshot[modelLoadAction]
type warmPoolModelSnapshot = warmpool.FleetModel
type warmPoolCandidate = warmpool.Candidate
type warmPoolQueuePressure = warmpool.QueuePressure
type warmColdReason = warmpool.ColdReason

const (
	warmColdEligible       = warmpool.ColdEligible
	warmColdOfflineUntrust = warmpool.ColdOfflineUntrust
	warmColdPendingLoad    = warmpool.ColdPendingLoad
	warmColdNotIdle        = warmpool.ColdNotIdle
	warmColdThermal        = warmpool.ColdThermal
	warmColdTrust          = warmpool.ColdTrust
	warmColdStaleChallenge = warmpool.ColdStaleChallenge
	warmColdNotServing     = warmpool.ColdNotServing
	warmColdDedicated      = warmpool.ColdDedicated
	warmColdTooLarge       = warmpool.ColdTooLarge
	warmColdNoFreeForLoad  = warmpool.ColdNoFreeForLoad
	warmColdStateRestoring = warmpool.ColdStateRestoring
)

func newWarmPoolController(r *Registry, cfg WarmPoolConfig) *warmPoolController {
	if r == nil {
		return warmpool.NewController[modelLoadAction](cfg, warmpool.Bindings[modelLoadAction]{})
	}
	return warmpool.NewController(cfg, warmpool.Bindings[modelLoadAction]{
		FleetSnapshot:    r.warmPoolFleetSnapshot,
		PendingCount:     r.pendingModelLoadCount,
		Reserve:          r.reservePendingModelLoads,
		Send:             r.sendModelLoadActions,
		IsDedicatedModel: r.IsDedicatedModel,
		Action: func(providerID, modelID string) modelLoadAction {
			return modelLoadAction{providerID: providerID, modelID: modelID}
		},
		Logger: func() *slog.Logger { return r.logger },
	})
}

func (r *Registry) ConfigureWarmPool(cfg WarmPoolConfig) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.warmPool == nil {
		r.warmPool = newWarmPoolController(r, cfg)
		return
	}
	r.warmPool.Configure(cfg)
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
	go controller.Run(ctx)
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
	if controller == nil || !controller.Enabled() || controller.ObserveOnly() {
		return false
	}
	return controller.RequestTrigger()
}

// TriggerWarmPool runs one active warm-pool planning pass immediately. It is a
// used by tests and administrative callers that need the resulting snapshots.
// Hot request paths should use RequestWarmPoolTrigger so bursts are coalesced.
func (r *Registry) TriggerWarmPool() []WarmPoolSnapshot {
	r.mu.RLock()
	controller := r.warmPool
	r.mu.RUnlock()
	if controller == nil || !controller.Enabled() || controller.ObserveOnly() {
		return nil
	}
	return controller.Tick(time.Now())
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
	return controller.LatestSnapshots()
}
