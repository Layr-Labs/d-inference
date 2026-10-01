package registry

import (
	"math"
	"slices"
	"time"

	"github.com/eigeninference/d-inference/coordinator/modelpolicy"
	"github.com/eigeninference/d-inference/coordinator/protocol"
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
		demand = autopilot.WithQueuedDemand(demand, r.queue.autopilotSamples(now, activeIDs))
	}
	byModel := make(map[string]map[string]autopilot.DemandView)
	for key, d := range demand {
		model := autopilot.ModelID(key)
		if byModel[model] == nil {
			byModel[model] = map[string]autopilot.DemandView{}
		}
		byModel[model][key] = d
	}
	f := autopilotFleet{Fleet: autopilot.Fleet{Demand: demand, Floors: map[string]int{}, Excluded: map[string]int{}}, sessions: map[string]*Provider{}}
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
		f.sessions[p.ID] = p
		p.mu.Lock()
		n := autopilot.Node{ID: p.ID, Seq: p.capacitySeq, Managed: providerAutopilotManagedLocked(p) || (c.config.ObserveOnly && providerAutopilotConsentedLocked(p) && !p.ModelAutopilot.Paused), Pending: providerAutopilotTransitionLocked(p), MemoryPressure: p.SystemMetrics.MemoryPressure, Fits: map[string]autopilot.ModelFit{}}
		n.UnscopedBusy = unscoped[p.ID]
		n.Uncertain = p.autopilotPending != nil && p.autopilotPending.Uncertain
		maxAge := c.config.ControlSnapshotMaxAge()
		if !providerAutopilotControlActiveLocked(p) {
			// Ordinary, waiting, observed and explicitly paused providers may
			// legitimately use a slower heartbeat. Preserve their donor credit
			// through the normal serving window. Active control renewals force
			// fresh capacity reports and retain the stricter mutation budget.
			maxAge = max(maxAge, DefaultProviderHeartbeatTimeout)
		}
		fresh := !p.capacitySamplesAt.IsZero() && now.Sub(p.capacitySamplesAt) <= maxAge && p.BackendCapacity != nil
		if !fresh || p.PrivateOnly {
			f.Excluded["stale_or_private"]++
			p.mu.Unlock()
			f.Nodes = append(f.Nodes, n)
			continue
		}
		n.State = autopilot.CloneState(p.ModelAutopilot)
		allIdle := !providerDrainingLocked(p, now) && p.pendingCount() == 0 && !warmPoolBackendSlotBusyLocked(p) && !n.UnscopedBusy
		n.Idle = (p.ModelAutopilot == nil || !p.ModelAutopilot.Paused) && allIdle && !n.Pending && !now.Before(p.autopilotBackoffUntil) && !r.providerHasPendingLoad(p.ID) && p.SystemMetrics.ThermalState != "critical" && p.SystemMetrics.ThermalState != "serious" && p.SystemMetrics.CPUUsage < .9
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
			if !r.providerPassesRoutingGatesLocked(p, model.ID, RequestTraits{}, false, now) {
				continue
			}
			found := false
			for key, d := range byModel[model.ID] {
				found = true
				if !r.providerPassesRoutingGatesLocked(p, model.ID, requestTraitsForAutopilot(d.Requirements), false, now) || (d.RequiresVision && !model.IsVision) {
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
	// Stable traversal makes equal-score decisions reproducible.
	slices.SortFunc(f.Nodes, func(a, b autopilot.Node) int {
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

func (r *Registry) autopilotModelFitLocked(p *Provider, model string, d autopilot.DemandView, cfg autopilot.Config) autopilot.ModelFit {
	solo := r.resolvedSoloModelTPSLocked(p, model)
	_, prefill := resolvedModelTPSLocked(p, model)
	cap := r.effectiveMaxConcurrencyForModelRateLocked(p, model, solo)
	floor := 15.0
	if r.warmPool != nil {
		floor = r.warmPool.config.DecodeFloorTPS
	}
	qc := min(cap, qualityConcurrency(solo.tps, floor, effectiveTPSLoadFactor, cap, 1))
	decode := solo.tps / (1 + effectiveTPSLoadFactor*float64(qc))
	if profile := qualifiedPerformanceProfileLocked(p, model); profile != nil {
		qc = profile.concurrencyForDecodeFloor(cap, floor)
		if point, ok := profile.batchAt(qc); ok {
			decode = point.AggregateDecodeTPS / float64(qc)
			if point.Width != qc {
				decode = point.DecodeP10TPS
			}
			prefill = point.PrefillTPS
		}
	}
	if solo.tps <= 0 || prefill <= 0 || qc < 1 {
		return autopilot.ModelFit{}
	}
	prompt, output := max(1, d.PromptTokens), max(1, d.OutputTokens)
	if d.Requests == 0 && d.Queued == 0 && d.InFlight == 0 {
		prompt = 512
		output = 256
	}
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
	if p.ModelAutopilot != nil {
		hash := ""
		for _, info := range p.Models {
			if info.ID == model {
				hash = info.WeightHash
				break
			}
		}
		for _, timing := range p.ModelAutopilot.LoadHistory {
			age := time.Since(time.UnixMilli(timing.MeasuredAtMS))
			if timing.ModelID == model && hash != "" && timing.WeightHash == hash && timing.LoadMS > 0 && timing.LoadMS <= 1800000 && age >= 0 && age < 7*24*time.Hour {
				load = math.Max(1, float64(timing.LoadMS)/1000)
			}
		}
	}
	tail := max(prompt, d.TailPromptTokens)
	deadline := modelpolicy.CoordinatorFirstContentDeadline(model, tail, 5*time.Second).Seconds()
	first := float64(tail)/prefill + 1/solo.tps + math.Max(0, p.Reputation.AvgResponseTime.Seconds())
	if d.DeadlineKnown {
		deadline = d.DeadlineSeconds
	}
	entry := r.modelCatalog[model]
	weights := math.Max(r.catalogSizeGBLocked(model), advertisedModelSizeGBLocked(p, model)) * coldLoadCatalogGBToMemGiB
	offload := advertisedOffloadedMemoryGBLocked(p, model, r.catalogSizeGBLocked(model))
	if finitePositiveMemory(offload) {
		weights = offload
	}
	_, sampleCount := r.tpsRegistry.SoloMedian(model, chipClassKey(p.Hardware))
	fit := autopilot.ModelFit{Rate: rate, ServiceSeconds: service, LoadSeconds: load, WeightsGiB: weights, Restricted: len(entry.RequiredProviderCapabilities) > 0, Measured: sampleCount >= qualityCapSoloMinSamples, MeetsDeadline: (d.DeadlineKnown && deadline <= 0) || first <= deadline*.8}
	if !modelFitsHardware(r.catalogMinRAMGbLocked(model), r.catalogSizeGBLocked(model), float64(p.Hardware.MemoryGB)) {
		fit.MeetsDeadline = false
	}
	// Reuse the scheduler's model-specific structural KV arithmetic.
	// It is only an upper-bound prefilter for cold models; a completed load
	// must still report actual usable budgets before receiving capacity credit.
	budget := coldTokenBudgetEstimateWithOffload(float64(p.Hardware.MemoryGB), r.catalogSizeGBLocked(model), offload, 0, model)
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
	if (d.Requests > 0 || d.Queued > 0 || d.InFlight > 0) && (budget <= 0 || envelope > budget) {
		fit.MeetsDeadline = false
	}
	return fit
}
