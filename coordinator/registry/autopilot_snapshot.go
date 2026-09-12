package registry

import (
	"math"
	"slices"
	"time"

	"github.com/eigeninference/d-inference/coordinator/modelpolicy"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func (r *Registry) autopilotFleetSnapshot(c *modelAutopilotController, now time.Time) autopilotFleet {
	demand := c.demand.snapshot(now, c.config.DemandWindow)
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.autopilotFleetSnapshotLocked(c, demand, now)
}

// r.mu held; p.mu is acquired and released per provider. No IO or planning sort
// runs under these locks. Reservation calls this with r.mu exclusive so donor
// protection is recalculated against current, not stale proposed, placements.
func (r *Registry) autopilotFleetSnapshotLocked(c *modelAutopilotController, demand map[string]autopilotDemandView, now time.Time) autopilotFleet {
	f := autopilotFleet{Demand: demand, Floors: map[string]int{}, Occupancy: map[string]int{}, Excluded: map[string]int{}}
	if r.warmPool != nil {
		for m, n := range r.warmPool.config.MinWarmByModel {
			f.Floors[m] = n
		}
	}
	for key, deadline := range r.pendingModelLoads {
		if now.Before(deadline) && !r.pendingModelLoadStarted[key].IsZero() {
			f.LegacyPending++
		}
	}
	for _, p := range r.providers {
		p.mu.Lock()
		n := autopilotNode{ID: p.ID, Session: p, Seq: p.capacitySeq, Managed: providerAutopilotManagedLocked(p), Pending: providerAutopilotTransitionLocked(p), MemoryPressure: p.SystemMetrics.MemoryPressure, Fits: map[string]autopilotModelFit{}}
		n.Uncertain = p.autopilotPending != nil && p.autopilotPending.Uncertain
		fresh := !p.capacitySamplesAt.IsZero() && now.Sub(p.capacitySamplesAt) <= c.config.MaxSnapshotAge && p.BackendCapacity != nil
		if !fresh || p.PrivateOnly {
			f.Excluded["stale_or_private"]++
			p.mu.Unlock()
			f.Nodes = append(f.Nodes, n)
			continue
		}
		n.State = cloneAutopilotState(p.ModelAutopilot)
		allIdle := p.pendingCount() == 0 && !warmPoolBackendSlotBusyLocked(p)
		n.Idle = allIdle && !n.Pending && !now.Before(p.autopilotBackoffUntil) && !r.providerHasPendingLoad(p.ID) && p.SystemMetrics.ThermalState != "critical" && p.SystemMetrics.ThermalState != "serious" && p.SystemMetrics.CPUUsage < .9
		if n.Managed && !autopilotStateMatchesCapacity(p) {
			n.Idle = false
			f.Excluded["unreconciled_state"]++
		}
		for _, slot := range p.BackendCapacity.Slots {
			f.Occupancy[slot.Model] += max(0, slot.NumRunning) + max(0, slot.NumWaiting)
		}
		for _, model := range p.Models {
			d := demand[model.ID]
			if !r.providerPassesRoutingGatesLocked(p, model.ID, RequestTraits{HasTools: d.HasTools, RequiresToolConstraint: d.RequiresToolConstraint}, false, now) || (d.RequiresVision && !model.IsVision) {
				continue
			}
			fit := r.autopilotModelFitLocked(p, model.ID, d, c.config)
			if fit.Rate <= 0 {
				f.Excluded["unknown_service"]++
				continue
			}
			n.Fits[model.ID] = fit
			for _, slot := range p.BackendCapacity.Slots {
				if slot.Model == model.ID && (slot.State == "idle" || slot.State == "running") {
					n.Residents = append(n.Residents, model.ID)
					break
				}
			}
		}
		// Do not authorize a plan that ignores an off-catalog/local resident or
		// resident rejected by current safety gates. Its owner retains control.
		if n.Managed && !slices.Equal(sortedAutopilotStrings(n.Residents), autopilotResidentIDs(n.State)) {
			n.Idle = false
			f.Excluded["unmanaged_resident"]++
		}
		if pending := p.autopilotPending; pending != nil && n.Managed && !pending.Uncertain && pending.Status != protocol.LoadModelStatusFailed && now.Sub(pending.SentAt) <= c.config.CommandWatchdog {
			futureResidents := []string{}
			for _, model := range pending.Command.ExpectedResidentModels {
				if !slices.Contains(pending.Command.UnloadModelIDs, model) {
					futureResidents = append(futureResidents, model)
				}
			}
			if pending.Command.LoadModelID != "" {
				futureResidents = append(futureResidents, pending.Command.LoadModelID)
			}
			// Recompute against current catalog/runtime gates and workload. Stale
			// or revoked capacity keeps its fence, never an optimistic credit.
			n.FutureResidents = futureResidents
		}
		p.mu.Unlock()
		f.Nodes = append(f.Nodes, n)
	}
	if r.queue != nil {
		for _, m := range r.queue.QueuedModels() {
			f.Occupancy[m] += r.queue.QueueSize(m)
		}
	}
	// Stable traversal makes equal-score decisions reproducible.
	slices.SortFunc(f.Nodes, func(a, b autopilotNode) int {
		if a.ID < b.ID {
			return -1
		}
		if a.ID > b.ID {
			return 1
		}
		return 0
	})
	return f
}

func sortedAutopilotStrings(values []string) []string {
	out := append([]string(nil), values...)
	slices.Sort(out)
	return out
}

func (r *Registry) autopilotModelFitLocked(p *Provider, model string, d autopilotDemandView, cfg AutopilotConfig) autopilotModelFit {
	solo := r.resolvedSoloModelTPSLocked(p, model)
	_, prefill := resolvedModelTPSLocked(p, model)
	cap := r.effectiveMaxConcurrencyForModelRateLocked(p, model, solo)
	floor := 15.0
	if r.warmPool != nil {
		floor = r.warmPool.config.DecodeFloorTPS
	}
	qc := min(cap, qualityConcurrency(solo.tps, floor, effectiveTPSLoadFactor, cap, 1))
	if solo.tps <= 0 || prefill <= 0 || qc < 1 {
		return autopilotModelFit{}
	}
	prompt, output := max(1, d.PromptTokens), max(1, d.OutputTokens)
	if d.Requests == 0 {
		prompt = 512
		output = 256
	}
	decode := solo.tps / (1 + effectiveTPSLoadFactor*float64(qc))
	service := math.Max(.1, float64(prompt)/prefill+float64(output)/decode)
	// Smooth sparse job outcomes toward a modest prior; never mistake a new
	// machine's zero jobs for a perfect measured success rate.
	reliability := (float64(max(0, p.Reputation.SuccessfulJobs)) + 9) / (float64(max(0, p.Reputation.TotalJobs)) + 10)
	reliability = math.Max(.1, math.Min(1, reliability))
	resourceFactor := math.Max(.25, 1-.5*p.SystemMetrics.MemoryPressure-.25*p.SystemMetrics.CPUUsage)
	if p.SystemMetrics.ThermalState == "fair" {
		resourceFactor *= .85
	}
	if p.SystemMetrics.ThermalState == "serious" || p.SystemMetrics.ThermalState == "critical" {
		resourceFactor *= .5
	}
	rate := float64(qc) / service * cfg.TargetUtilization * reliability * resourceFactor
	load := cfg.LoadTimePrior.Seconds() // unmeasured prior, not an observed quantile
	for _, slot := range p.BackendCapacity.Slots {
		if slot.Model == model && slot.ModelLoadTimeMS > 0 {
			load = math.Max(1, float64(slot.ModelLoadTimeMS)/1000)
			break
		}
	}
	tail := max(prompt, d.TailPromptTokens)
	deadline := modelpolicy.CoordinatorFirstContentDeadline(model, tail, 5*time.Second).Seconds()
	first := float64(tail)/prefill + 1/solo.tps + math.Max(0, p.Reputation.AvgResponseTime.Seconds())
	entry := r.modelCatalog[model]
	weights := math.Max(r.catalogSizeGBLocked(model), advertisedModelSizeGBLocked(p, model)) * 1.2 * 1e9 / (1 << 30)
	_, sampleCount := r.tpsRegistry.SoloMedian(model, chipClassKey(p.Hardware))
	fit := autopilotModelFit{Rate: rate, ServiceSeconds: service, LoadSeconds: load, WeightsGiB: weights, Restricted: len(entry.RequiredProviderCapabilities) > 0, Measured: sampleCount >= qualityCapSoloMinSamples, MeetsDeadline: first <= deadline*.8}
	if !modelFitsHardware(r.catalogMinRAMGbLocked(model), r.catalogSizeGBLocked(model), float64(p.Hardware.MemoryGB)) {
		fit.MeetsDeadline = false
	}
	// Reuse the scheduler's version/model-specific structural KV arithmetic.
	// It is only an upper-bound prefilter for cold models; a completed load
	// must still report actual usable budgets before receiving capacity credit.
	budget := coldTokenBudgetEstimate(float64(p.Hardware.MemoryGB), r.catalogSizeGBLocked(model), 0, p.Version, model)
	for _, slot := range p.BackendCapacity.Slots {
		if slot.Model == model && (slot.State == "running" || slot.State == "idle") {
			budget = slot.ActiveTokenBudgetMax
			break
		}
	}
	maxOutput := d.RequestedMaxTokens
	if maxOutput <= 0 {
		maxOutput = 256
	}
	envelope := int64(tail) + int64(maxOutput)
	if d.Requests > 0 && (budget <= 0 || envelope > budget) {
		fit.MeetsDeadline = false
	}
	return fit
}
