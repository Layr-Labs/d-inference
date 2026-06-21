package registry

import (
	"sort"
	"time"
)

// Placement controller (DAR-345 one-model-per-machine). It turns the warm
// pool's per-model demand targets into an exclusive model→machine assignment:
// each managed machine holds exactly one public model, the fleet is partitioned
// by demand (priority/floor/cap), and surplus machines are switched into
// deficit pools — conservatively, reusing the warm pool's anti-thrash budget
// (MinDwell per machine, MaxGlobalPendingLoads + MaxLoadsPerTick switch budget,
// the per-(provider,model) dispatch-load cooldown). The allocator is a pure,
// deterministic function (planPlacement) so it is fully unit-testable; the
// builder/enforcer below are the only parts that touch live registry state.

// placementModel is one pool's demand for the allocator.
type placementModel struct {
	model    string
	need     int // desired machine count (Little's Law target this tick)
	floor    int // operator minimum (MinWarmByModel)
	priority int // higher wins when total demand exceeds the fleet
}

// placementMachine is one routable, managed-eligible machine.
type placementMachine struct {
	id         string
	current    string             // currently assigned model ("" = unmanaged/unassigned)
	assignedAt time.Time          // last assignment change (zero for never-assigned)
	idle       bool               // no in-flight work — safe to switch without dropping requests
	capable    map[string]float64 // model -> score for models this machine can hold (on disk + fits + not cooling down)
}

type placementAction struct {
	machineID string
	model     string
}

// placementPlan is the allocator output: the normalized desired assignment, the
// observed current assignment, and the switches to apply this tick.
type placementPlan struct {
	desired map[string]int
	current map[string]int
	actions []placementAction
}

// planPlacement is the pure allocator. Given per-model demand and the current
// machine assignment, it (1) normalizes desired machine counts to the fleet by
// floor-then-priority, (2) diffs against current, and (3) greedily switches
// idle, off-dwell, capable surplus/unmanaged machines into the highest-priority
// deficit pools, bounded by switchBudget. Deterministic: ties break by model
// name and machine id.
func planPlacement(models []placementModel, machines []placementMachine, minDwell time.Duration, switchBudget int, now time.Time) placementPlan {
	plan := placementPlan{desired: map[string]int{}, current: map[string]int{}}

	// Current assignment, counted from the machines themselves (independent of
	// whether the model still has demand — a machine on a now-undemanded model is
	// surplus and releasable).
	for _, m := range machines {
		if m.current != "" {
			plan.current[m.current]++
		}
	}

	fleetSize := len(machines)
	if fleetSize == 0 || switchBudget <= 0 {
		return plan
	}

	// Stable priority order: higher priority first, then model name.
	ordered := append([]placementModel(nil), models...)
	sort.Slice(ordered, func(i, j int) bool {
		if ordered[i].priority != ordered[j].priority {
			return ordered[i].priority > ordered[j].priority
		}
		return ordered[i].model < ordered[j].model
	})

	// Normalize desired counts. Pass 1 reserves operator floors (so a low-priority
	// pool with demand is never fully starved by a high-priority one); pass 2
	// fills remaining capacity by demand, both in priority order, capped at the
	// fleet size.
	remaining := fleetSize
	for _, m := range ordered {
		f := m.floor
		if f > remaining {
			f = remaining
		}
		if f < 0 {
			f = 0
		}
		plan.desired[m.model] = f
		remaining -= f
	}
	for _, m := range ordered {
		want := m.need
		if want < m.floor {
			want = m.floor // effective need is at least the floor
		}
		extra := want - plan.desired[m.model]
		if extra > remaining {
			extra = remaining
		}
		if extra > 0 {
			plan.desired[m.model] += extra
			remaining -= extra
		}
	}

	// Deficit/surplus per model.
	surplus := map[string]int{} // current - desired, only positive entries
	for model, cur := range plan.current {
		if d := cur - plan.desired[model]; d > 0 {
			surplus[model] = d
		}
	}

	// Track which machines we've already moved this tick.
	used := map[string]bool{}

	// A machine is an eligible SOURCE iff it is idle, past min-dwell (unmanaged
	// machines have a zero assignedAt and are always past dwell), and either
	// unmanaged or sitting in a surplus pool.
	dwellOK := func(m placementMachine) bool {
		if m.current == "" || m.assignedAt.IsZero() {
			return true
		}
		return now.Sub(m.assignedAt) >= minDwell
	}

	// Fill deficits, highest-priority / largest-deficit first.
	for _, m := range ordered {
		for switchBudget > 0 {
			deficit := plan.desired[m.model] - plan.current[m.model]
			if deficit <= 0 {
				break
			}
			best := -1
			bestScore := -1.0
			bestUnmanaged := false
			for i, mach := range machines {
				if used[mach.id] || mach.id == "" {
					continue
				}
				if !mach.idle || !dwellOK(mach) {
					continue
				}
				score, ok := mach.capable[m.model]
				if !ok {
					continue // can't hold this model (not on disk / won't fit / cooling down)
				}
				unmanaged := mach.current == ""
				if !unmanaged && surplus[mach.current] <= 0 {
					continue // its pool is not over-provisioned — don't yank it
				}
				// Prefer unmanaged sources (free capacity) over yanking a surplus
				// machine; then prefer the higher-scoring (faster/larger) machine.
				better := best < 0 ||
					(unmanaged && !bestUnmanaged) ||
					(unmanaged == bestUnmanaged && score > bestScore)
				if better {
					best, bestScore, bestUnmanaged = i, score, unmanaged
				}
			}
			if best < 0 {
				break // no eligible source for this deficit
			}
			mach := machines[best]
			used[mach.id] = true
			if mach.current != "" {
				plan.current[mach.current]--
				surplus[mach.current]--
			}
			plan.current[m.model]++
			plan.actions = append(plan.actions, placementAction{machineID: mach.id, model: m.model})
			switchBudget--
		}
	}
	return plan
}

// buildPlacementInputs scans the live fleet into allocator inputs. Only online,
// trusted, non-PrivateOnly, manageable (version-gated) machines are eligible to
// be placed; PrivateOnly/owner machines and pre-feature providers stay unmanaged
// (the routing gate leaves AssignedModel=="" machines unconstrained). demand is
// the model→target-machine map from the warm-pool snapshots.
func (r *Registry) buildPlacementInputs(demand map[string]int, now time.Time) ([]placementModel, []placementMachine) {
	floors := map[string]int{}
	priorities := map[string]int{}
	if r.warmPool != nil {
		floors = r.warmPool.config.MinWarmByModel
		priorities = r.warmPool.config.ModelPriority
	}

	// The model universe: anything with demand, an operator floor, or a configured
	// priority.
	modelSet := map[string]struct{}{}
	for m := range demand {
		modelSet[m] = struct{}{}
	}
	for m := range floors {
		modelSet[m] = struct{}{}
	}
	for m := range priorities {
		modelSet[m] = struct{}{}
	}
	models := make([]placementModel, 0, len(modelSet))
	for m := range modelSet {
		models = append(models, placementModel{
			model:    m,
			need:     demand[m],
			floor:    floors[m],
			priority: priorities[m],
		})
	}

	r.mu.RLock()
	defer r.mu.RUnlock()
	machines := make([]placementMachine, 0, len(r.providers))
	for id, p := range r.providers {
		p.mu.Lock()
		eligible := p.Status != StatusOffline && p.Status != StatusUntrusted && !p.PrivateOnly && r.manageableLocked(p)
		if !eligible {
			p.mu.Unlock()
			continue
		}
		idle := p.pendingCount() == 0 && !warmPoolBackendSlotBusyLocked(p)
		capable := make(map[string]float64)
		for m := range modelSet {
			if !r.providerServesCatalogModelLocked(p, m) {
				continue
			}
			if r.dispatchLoadCooldownActiveLocked(id, m, now) {
				continue // just failed to load m here — don't reassign it
			}
			if !modelFitsHardware(r.catalogMinRAMGbLocked(m), r.catalogSizeGBLocked(m), float64(p.Hardware.MemoryGB)) {
				continue
			}
			score := resolvedDecodeTPS(p)
			if score <= 0 {
				score = float64(p.Hardware.MemoryGB)
			}
			capable[m] = score
		}
		machines = append(machines, placementMachine{
			id:         id,
			current:    p.AssignedModel,
			assignedAt: p.AssignedAt,
			idle:       idle,
			capable:    capable,
		})
		p.mu.Unlock()
	}
	return models, machines
}

// manageableLocked reports whether a provider may be bound to a pool. Defaults
// permissive when no version gate is wired (tests); the api sets the gate to
// providerSupportsModelAssignment so pre-feature providers stay unmanaged.
// Caller holds p.mu.
func (r *Registry) manageableLocked(p *Provider) bool {
	if r.manageableProvider == nil {
		return true
	}
	return r.manageableProvider(p.Backend, p.Version)
}

// SetManageableProviderFunc wires the version/backend gate the placement
// controller uses to decide which providers may be assigned a pool. Set once at
// startup. nil = permissive (test default).
func (r *Registry) SetManageableProviderFunc(fn func(backend, version string) bool) {
	r.mu.Lock()
	r.manageableProvider = fn
	r.mu.Unlock()
}

// runPlacement runs one placement pass off the warm-pool tick. In shadow mode
// (PlacementEnforce=false or ObserveOnly) it only computes + records the plan;
// when enforcing it reserves the shared pending-load budget and pushes
// assign_model to switch machines between pools.
func (c *warmPoolController) runPlacement(now time.Time, snapshots []WarmPoolSnapshot) {
	if c == nil || c.registry == nil || !c.config.PlacementEnabled {
		return
	}
	demand := make(map[string]int, len(snapshots))
	for _, s := range snapshots {
		demand[s.Model] = s.TargetWarm
	}

	// Switch budget shares the global pending-load reservation with warm loads
	// (both reserve via pendingModelLoads), so a tick never moves more than a few
	// machines and fleet capacity never dips.
	budget := c.config.MaxLoadsPerTick
	if budget <= 0 {
		budget = 1
	}
	if rem := c.config.MaxGlobalPendingLoads - c.registry.pendingModelLoadCount(now); rem < budget {
		budget = rem
	}
	if budget < 0 {
		budget = 0
	}

	models, machines := c.registry.buildPlacementInputs(demand, now)
	plan := planPlacement(models, machines, c.config.MinDwell, budget, now)
	c.storePlacement(plan, now)

	enforce := c.config.PlacementEnforce && !c.config.ObserveOnly
	if c.registry.logger != nil {
		c.registry.logger.Info("placement_tick",
			"enforce", enforce,
			"machines", len(machines),
			"pools", len(plan.desired),
			"switches", len(plan.actions),
		)
	}
	if !enforce || len(plan.actions) == 0 {
		return
	}

	// Reserve the pending-load budget for the switches, then assign + push.
	loadActions := make([]modelLoadAction, 0, len(plan.actions))
	for _, a := range plan.actions {
		loadActions = append(loadActions, modelLoadAction{providerID: a.machineID, modelID: a.model})
	}
	reserved := c.registry.reservePendingModelLoads(loadActions, now)
	for _, a := range reserved {
		epoch, changed, err := c.registry.AssignProviderModel(a.providerID, a.modelID)
		if err != nil || !changed {
			// Couldn't record the assignment (provider gone / already serving it):
			// release the reservation we just took so it isn't stranded for the TTL.
			c.registry.ClearPendingModelLoad(a.providerID, a.modelID)
			continue
		}
		if err := c.registry.SendAssignModel(a.providerID, a.modelID, epoch); err != nil {
			// Push failed (e.g. a half-dead WebSocket). Release the pending
			// reservation so the next tick can re-attempt rather than waiting out
			// the 2-min TTL; the provider stays AssignmentStateLoading (not
			// routable) until it acks or is evicted. Mirrors the load_model path.
			c.registry.ClearPendingModelLoad(a.providerID, a.modelID)
			if c.registry.logger != nil {
				c.registry.logger.Warn("placement assign_model push failed",
					"provider_id", a.providerID, "model_id", a.modelID, "error", err)
			}
		}
	}
}

// PlacementSnapshot is a read-only view of the latest placement plan for
// observability (assigned-pool sizes, co-residency audit, switch count).
type PlacementSnapshot struct {
	Desired  map[string]int
	Current  map[string]int
	Switches int
	At       time.Time
}

func (c *warmPoolController) storePlacement(plan placementPlan, now time.Time) {
	c.lastMu.Lock()
	defer c.lastMu.Unlock()
	c.lastPlacement = PlacementSnapshot{
		Desired:  plan.desired,
		Current:  plan.current,
		Switches: len(plan.actions),
		At:       now,
	}
}

// LatestPlacementSnapshot returns the most recent placement plan, or (zero,
// false) if the placement controller has not run.
func (r *Registry) LatestPlacementSnapshot() (PlacementSnapshot, bool) {
	r.mu.RLock()
	c := r.warmPool
	r.mu.RUnlock()
	if c == nil {
		return PlacementSnapshot{}, false
	}
	c.lastMu.RLock()
	defer c.lastMu.RUnlock()
	if c.lastPlacement.At.IsZero() {
		return PlacementSnapshot{}, false
	}
	return c.lastPlacement, true
}
