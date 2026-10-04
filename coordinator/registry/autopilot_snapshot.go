package registry

import (
	"math"
	"slices"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotcontrol"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"

	memorypolicy "github.com/eigeninference/d-inference/coordinator/internal/registry/memorypolicy"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

func (r *Registry) autopilotFleetSnapshot(c *modelAutopilotController, now time.Time) autopilotFleet {
	demand := c.demand.ShapeSnapshot(now, c.config.DemandWindow)
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.autopilotFleetSnapshotLocked(c, demand, now)
}

// r.mu held; p.mu is acquired and released per provider. No IO or planning sort
// runs under these locks. Reservation calls this with r.mu exclusive so donor
// protection is recalculated against current, not stale proposed, placements.
func (r *Registry) autopilotFleetSnapshotLocked(c *modelAutopilotController, demand map[string]autopilot.DemandView, now time.Time) autopilotFleet {
	active, activeIDs, unscoped := r.autopilotActiveSamplesLocked()
	demand = autopilot.WithActiveDemand(demand, active)
	if r.queue != nil {
		demand = autopilot.WithQueuedDemand(demand, r.queue.AutopilotSamples(now, activeIDs))
	}
	byModel := make(map[string]map[string]autopilot.DemandView)
	for key, d := range demand {
		model := autopilot.ModelID(key)
		if byModel[model] == nil {
			byModel[model] = map[string]autopilot.DemandView{}
		}
		byModel[model][key] = d
	}
	f := autopilotcontrol.NewFleet[*Provider](demand)
	if r.warmPool != nil {
		for m, n := range r.warmPool.config.MinWarmByModel {
			f.Floors[m] = n
		}
	}
	f.LegacyPending = r.pendingLoads.CountStartedBeforeExpiry(now)
	for _, p := range r.providers {
		p.mu.Lock()
		placement := p.autopilotState.Placement(p.ModelAutopilot, now, c.config.CommandWatchdog)
		n := autopilot.Node{ID: p.ID, Seq: p.capacitySeq, Managed: providerAutopilotManagedLocked(p) || (c.config.ObserveOnly && providerAutopilotConsentedLocked(p) && !p.ModelAutopilot.Paused), Pending: placement.Pending, MemoryPressure: p.SystemMetrics.MemoryPressure, Fits: map[string]autopilot.ModelFit{}}
		n.UnscopedBusy = unscoped[p.ID]
		n.Uncertain = placement.Uncertain
		maxAge := c.config.ControlSnapshotMaxAge()
		if !providerAutopilotControlActiveLocked(p) {
			// Ordinary, waiting, observed and explicitly paused providers may
			// legitimately use a slower heartbeat. Preserve their donor credit
			// through the normal serving window. Active control renewals force
			// fresh capacity reports and retain the stricter mutation budget.
			maxAge = max(maxAge, DefaultProviderHeartbeatTimeout)
		}
		fresh := p.capacitySamples.Fresh(now, maxAge) && p.BackendCapacity != nil
		if !fresh || p.PrivateOnly {
			f.Excluded["stale_or_private"]++
			p.mu.Unlock()
			f.Add(n, p)
			continue
		}
		n.State = autopilot.CloneState(p.ModelAutopilot)
		allIdle := !providerDrainingLocked(p, now) && p.pendingCount() == 0 && !warmPoolBackendSlotBusyLocked(p) && !n.UnscopedBusy
		n.Idle = (p.ModelAutopilot == nil || !p.ModelAutopilot.Paused) && allIdle && !n.Pending && placement.Available && !r.providerHasPendingLoad(p.ID) && p.SystemMetrics.ThermalState != "critical" && p.SystemMetrics.ThermalState != "serious" && p.SystemMetrics.CPUUsage < .9
		if n.Managed && !autopilotStateMatchesCapacity(p) {
			n.Idle = false
			f.Excluded["unreconciled_state"]++
		}
		for _, model := range p.Models {
			if p.ModelAutopilot != nil && p.ModelAutopilot.Enabled && !providerAutopilotAllowsLocked(p, model.ID) {
				continue
			}
			// Keep base residency independent of a specialized request shape.
			// Each cohort earns capacity only from providers qualified for it.
			if !r.providerPassesAutopilotGatesLocked(p, model, RequestTraits{}, now) {
				continue
			}
			found := false
			for key, d := range byModel[model.ID] {
				found = true
				if !r.providerPassesAutopilotGatesLocked(p, model, RequestTraitsForAutopilot(d.Requirements), now) || (d.RequiresVision && !model.IsVision) {
					continue
				}
				fit := r.autopilotModelFitLocked(p, model.ID, d, c.config)
				if fit.Rate > 0 {
					n.Fits[key] = fit
				}
			}
			if !found {
				n.Fits[model.ID] = r.autopilotModelFitLocked(p, model.ID, autopilot.DemandView{}, c.config)
			}

			for _, slot := range p.BackendCapacity.Slots {
				if slot.Model == model.ID && (slot.State == "idle" || slot.State == "running") {
					n.Residents = append(n.Residents, model.ID)
					break
				}
			}
		}
		// Do not authorize a plan that ignores an off-catalog/local resident or
		// resident rejected by current safety gates. Its owner retains control.
		if n.Managed && !slices.Equal(autopilot.SortedStrings(n.Residents), autopilot.ResidentIDs(n.State)) {
			n.Idle = false
			f.Excluded["unmanaged_resident"]++
		}
		if n.Managed {
			n.FutureResidents = placement.FutureResidents
		}
		p.mu.Unlock()
		f.Add(n, p)
	}
	// Stable traversal makes equal-score decisions reproducible.
	f.Order()
	return f
}

func (r *Registry) autopilotModelFitLocked(p *Provider, model string, d autopilot.DemandView, cfg autopilot.Config) autopilot.ModelFit {
	solo := r.resolvedSoloModelTPSLocked(p, model)
	_, prefill := resolvedModelTPSLocked(p, model)
	cap := r.effectiveMaxConcurrencyForModelRateLocked(p, model, solo)
	floor := 15.0
	if r.warmPool != nil {
		floor = r.warmPool.config.DecodeFloorTPS
	}
	evidence := autopilotcontrol.FitEvidence{
		Model: model, SoloTPS: solo.tps, PrefillTPS: prefill, MaxConcurrency: cap,
		DecodeFloorTPS: floor, LoadFactor: effectiveTPSLoadFactor,
		Profile:        (*performance.Profile)(qualifiedPerformanceProfileLocked(p, model)),
		SuccessfulJobs: p.Reputation.SuccessfulJobs, TotalJobs: p.Reputation.TotalJobs,
		ResponseTime: p.Reputation.AvgResponseTime, Metrics: p.SystemMetrics,
	}
	if p.BackendCapacity != nil {
		evidence.Slots = p.BackendCapacity.Slots
	}
	if p.ModelAutopilot != nil {
		evidence.LoadHistory = p.ModelAutopilot.LoadHistory
		for _, info := range p.Models {
			if info.ID == model {
				evidence.WeightHash = info.WeightHash
				break
			}
		}
	}
	return autopilotcontrol.ModelFit(evidence, d, cfg, func() autopilotcontrol.FitLimits {
		entry := r.modelCatalog[model]
		weights := math.Max(r.catalogSizeGBLocked(model), advertisedModelSizeGBLocked(p, model)) * coldLoadCatalogGBToMemGiB
		offload := advertisedOffloadedMemoryGBLocked(p, model, r.catalogSizeGBLocked(model))
		if finitePositiveMemory(offload) {
			weights = offload
		}
		_, sampleCount := r.tpsRegistry.SoloMedian(model, chipClassKey(p.Hardware))
		// Structural KV is only a cold-model prefilter; a completed load must
		// still report actual usable budgets before receiving capacity credit.
		return autopilotcontrol.FitLimits{
			WeightsGiB: weights, Restricted: len(entry.RequiredProviderCapabilities) > 0,
			Measured:        sampleCount >= r.qualityPolicyLocked().MinSamples(),
			HardwareFits:    modelFitsHardware(r.catalogMinRAMGbLocked(model), r.catalogSizeGBLocked(model), float64(p.Hardware.MemoryGB)),
			ColdTokenBudget: memorypolicy.ColdTokenBudgetWithOffload(float64(p.Hardware.MemoryGB), r.catalogSizeGBLocked(model), offload, 0, model),
		}
	})
}
