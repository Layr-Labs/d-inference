package registry

import (
	"math"
	"slices"
	"sort"
	"time"
)

type autopilotCoverageView struct {
	Ready, Future, Need map[string]float64
	Warm                map[string]int
	Contribution        map[string]map[string]float64
	Reference           map[string]float64
	Workload            map[string]autopilotDemandView
}

// A shared GPU contributes at most one machine's execution time. Residency is
// not independent compute. Unqualified resident work can consume time, but it
// must not receive useful capacity credit or hide a deadline-qualified deficit.
func autopilotNodeContribution(n autopilotNode, residents []string, demand map[string]autopilotDemandView) map[string]float64 {
	out := make(map[string]float64)
	weights := make(map[string]float64)
	total := 0.0
	for _, model := range residents {
		fit := n.Fits[model]
		if !finiteAutopilotNonnegative(fit.Rate) || fit.Rate <= 0 {
			continue
		}
		rate := demand[model].Rate
		if !finiteAutopilotNonnegative(rate) {
			rate = 0
		}
		weight := rate / fit.Rate
		weights[model] = weight
		total += weight
	}
	if total == 0 {
		for model := range weights {
			weights[model] = 1
		}
		total = float64(len(weights))
	}
	if total > 0 && finiteAutopilotNonnegative(total) {
		for model, weight := range weights {
			if n.Fits[model].MeetsDeadline {
				out[model] = n.Fits[model].Rate * weight / total
			}
		}
	}
	return out
}

func autopilotCoverage(f autopilotFleet) autopilotCoverageView {
	c := autopilotCoverageView{
		Ready: map[string]float64{}, Future: map[string]float64{}, Need: map[string]float64{},
		Warm: map[string]int{}, Contribution: map[string]map[string]float64{},
		Reference: map[string]float64{}, Workload: map[string]autopilotDemandView{},
	}
	// Resolve once per model, not once per node/model (the fallback scans the
	// fleet). One reference prices the same recovered work on every recipient.
	models := make(map[string]bool)
	for m := range f.Demand {
		models[m] = true
	}
	for m := range f.Occupancy {
		models[m] = true
	}
	for m := range f.Floors {
		models[m] = true
	}
	for _, n := range f.Nodes {
		for m := range n.Fits {
			models[m] = true
		}
	}
	for m := range models {
		c.Reference[m] = autopilotReferenceService(f, m)
	}
	for m := range models {
		d := f.Demand[m]
		rate := d.Rate
		if !finiteAutopilotNonnegative(rate) {
			rate = 0
		}
		// Occupancy and offered-work estimates overlap. Use max, NEVER sum.
		// Include occupancy-only models whose first logical terminal has not
		// arrived yet, both in demand and in shared-GPU time allocation.
		c.Need[m] = math.Max(rate, float64(max(0, f.Occupancy[m]))/c.Reference[m])
		d.Rate = c.Need[m]
		c.Workload[m] = d
	}
	for _, node := range f.Nodes {
		if node.Pending {
			future := node.Future
			if node.FutureResidents != nil {
				future = autopilotNodeContribution(node, node.FutureResidents, c.Workload)
			}
			for m, rate := range future {
				if finiteAutopilotNonnegative(rate) {
					c.Future[m] += rate
				}
			}
			continue
		}
		contribution := autopilotNodeContribution(node, node.Residents, c.Workload)
		c.Contribution[node.ID] = contribution
		for model, rate := range contribution {
			c.Ready[model] += rate
			c.Warm[model]++
		}
	}
	return c
}

func autopilotFloor(f autopilotFleet, model string) int {
	floor := max(0, f.Floors[model])
	d := f.Demand[model]
	if d.Rate > 0 && (d.Requests >= 3 || d.CapacityShed > 0) {
		floor = max(1, floor)
	}
	return floor
}

func autopilotDonorsProtected(f autopilotFleet, c autopilotCoverageView, n autopilotNode) bool {
	// Loading fences the entire device, including retained co-residents. Debit
	// every contribution for the whole transition; future capacity cannot protect
	// a currently needed donor. Other commands are already absent from Ready.
	for _, m := range n.Residents {
		contribution, credited := c.Contribution[n.ID][m]
		if !credited {
			continue
		} // no useful capacity was credited to this resident
		if c.Warm[m]-1 < autopilotFloor(f, m) {
			return false
		}
		if c.Ready[m]-contribution+1e-9 < c.Need[m] {
			return false
		}
	}
	return true
}

func autopilotVictims(n autopilotNode, model string, cfg AutopilotConfig) ([]string, bool) {
	state := n.State
	if state == nil || state.FreeForLoadNoEvictGB == nil || state.MaxModelSlots < 1 {
		return nil, false
	}
	free := *state.FreeForLoadNoEvictGB
	slots := state.MaxModelSlots - len(state.ResidentModels)
	need := n.Fits[model].WeightsGiB
	if !finiteAutopilotNonnegative(free) || !finiteAutopilotNonnegative(need) || need <= 0 {
		return nil, false
	}
	if free >= need && slots > 0 {
		return []string{}, true
	}
	ordered := append([]string(nil), n.Residents...)
	byID := make(map[string]int)
	for i, m := range state.ResidentModels {
		if _, exists := byID[m.ModelID]; exists {
			return nil, false
		}
		byID[m.ModelID] = i
	}
	for _, id := range ordered {
		if _, exists := byID[id]; !exists {
			return nil, false
		}
	}
	sort.Slice(ordered, func(i, j int) bool {
		a, b := state.ResidentModels[byID[ordered[i]]].IdleSeconds, state.ResidentModels[byID[ordered[j]]].IdleSeconds
		if a == b {
			return ordered[i] < ordered[j]
		}
		return a > b
	})
	dwell := math.Max(cfg.MinDwell.Seconds(), float64(state.MinDwellSeconds))
	var victims []string
	for _, id := range ordered {
		m := state.ResidentModels[byID[id]]
		if slices.Contains(state.PinnedModels, id) || m.ResidentSeconds < dwell || m.IdleSeconds < dwell {
			continue
		}
		victims = append(victims, id)
		slots++
		// Only actual provider-authoritative reclaim credit, NEVER scanner padding.
		if m.ResidentGB != nil && finiteAutopilotNonnegative(*m.ResidentGB) {
			free += *m.ResidentGB
		}
		if free >= need && slots > 0 {
			return victims, true
		}
	}
	return nil, false
}

func planAutopilotAction(f autopilotFleet, cfg AutopilotConfig, now time.Time) *autopilotAction {
	c := autopilotCoverage(f)
	reference := c.Reference
	var best *autopilotAction
	models := make([]string, 0, len(c.Need))
	for m := range c.Need {
		models = append(models, m)
	}
	slices.Sort(models)
	for _, n := range f.Nodes {
		if !n.Managed || !n.Idle || n.Pending || !autopilotDonorsProtected(f, c, n) {
			continue
		}
		for _, m := range models {
			fit, eligible := n.Fits[m]
			if !eligible || !fit.MeetsDeadline || fit.Rate <= 0 || slices.Contains(n.Residents, m) {
				continue
			}
			floorShort := c.Warm[m] < autopilotFloor(f, m) && c.Future[m] == 0
			gap := c.Need[m] - c.Ready[m] - c.Future[m]
			if gap <= 0 && !floorShort {
				continue
			}
			victims, ok := autopilotVictims(n, m, cfg)
			if !ok {
				continue
			}
			futureResidents := []string{m}
			for _, old := range n.Residents {
				if !slices.Contains(victims, old) {
					futureResidents = append(futureResidents, old)
				}
			}
			future := autopilotNodeContribution(n, futureResidents, c.Workload)
			useful := math.Min(math.Max(0, gap), future[m])
			horizon := math.Min(300, cfg.MinDwell.Seconds())
			benefit := useful * reference[m] * math.Max(0, horizon-fit.LoadSeconds)
			// Actual quality contribution (not chip generation) ranks recipients.
			// The cold load prior and destroyed resident cache impose a switch cost.
			cost := fit.LoadSeconds + float64(len(victims))*cfg.MinBenefitSeconds
			if !fit.Measured {
				cost += cfg.MinBenefitSeconds
			}
			for _, old := range n.Residents {
				cost += c.Contribution[n.ID][old] * reference[old] * fit.LoadSeconds
			}
			if floorShort {
				benefit = math.Max(benefit, cost+cfg.MinBenefitSeconds+fit.Rate)
			}
			// Prefer to retain a scarce compatible device for an unmet restricted
			// workload. Capability comes from the catalog/runtime gate, never M5 age.
			if !fit.Restricted {
				for restricted, rf := range n.Fits {
					if rf.Restricted && rf.MeetsDeadline && c.Ready[restricted]+c.Future[restricted] < c.Need[restricted] {
						cost += horizon
					}
				}
			}
			benefit -= cost
			if benefit < cfg.MinBenefitSeconds {
				continue
			}
			if best == nil || benefit > best.Benefit || (benefit == best.Benefit && n.ID < best.Node.ID) {
				best = &autopilotAction{Node: n, Load: m, Unload: victims, Benefit: benefit, Future: future}
			}
		}
	}
	if best != nil || !cfg.AllowIdleUnload {
		return best
	}
	for _, n := range f.Nodes {
		if !n.Managed || !n.Idle || n.Pending || n.State == nil || !finiteAutopilotNonnegative(n.MemoryPressure) || n.MemoryPressure < .8 || !autopilotDonorsProtected(f, c, n) {
			continue
		}
		var victims []string
		for _, m := range n.State.ResidentModels {
			d := f.Demand[m.ModelID]
			if d.Rate > 0 || (!d.LastDemand.IsZero() && now.Sub(d.LastDemand) < cfg.IdleUnloadAfter) || slices.Contains(n.State.PinnedModels, m.ModelID) || m.ResidentSeconds < math.Max(cfg.MinDwell.Seconds(), float64(n.State.MinDwellSeconds)) || m.IdleSeconds < math.Max(cfg.IdleUnloadAfter.Seconds(), float64(n.State.MinDwellSeconds)) {
				continue
			}
			victims = append(victims, m.ModelID)
		}
		if len(victims) > 0 {
			var retained []string
			for _, m := range n.Residents {
				if !slices.Contains(victims, m) {
					retained = append(retained, m)
				}
			}
			return &autopilotAction{Node: n, Unload: victims, Future: autopilotNodeContribution(n, retained, c.Workload)}
		}
	}
	return nil
}

// One fixed valuation per model prevents slow recipients from being rewarded
// for taking longer to serve an identical request. Candidate-specific speed
// enters Rate, never the value assigned to a recovered request.
func autopilotReferenceService(f autopilotFleet, model string) float64 {
	if s := f.Demand[model].ServiceSeconds; finiteAutopilotNonnegative(s) && s > 0 {
		return s
	}
	var values []float64
	for _, n := range f.Nodes {
		if fit, ok := n.Fits[model]; ok && fit.MeetsDeadline && finiteAutopilotNonnegative(fit.ServiceSeconds) && fit.ServiceSeconds > 0 {
			values = append(values, fit.ServiceSeconds)
		}
	}
	if len(values) == 0 {
		return 10
	}
	slices.Sort(values)
	return values[len(values)/2]
}
