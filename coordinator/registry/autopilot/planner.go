package autopilot

import (
	"math"
	"slices"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/residency"
)

func Plan(f Fleet, cfg Config, now time.Time) *Action {
	c := Coverage(f)
	reference := c.Reference
	var best *Action
	hasPlacementNeed := false
	for key, need := range c.Need {
		if need > c.Ready[key]+c.Future[key] || c.Warm[ModelID(key)] < floor(f, ModelID(key)) {
			hasPlacementNeed = true
			break
		}
	}
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
			if !eligible || !fit.MeetsDeadline || fit.Rate <= 0 || slices.Contains(n.Residents, ModelID(m)) {
				continue
			}
			floorShort := c.Warm[ModelID(m)] < floor(f, ModelID(m)) && c.Future[m] == 0
			bootstrap := !hasPlacementNeed && len(n.Residents) == 0 && n.State != nil && n.State.LastCommandID == "" && c.Future[m] == 0
			floorShort = floorShort || bootstrap
			if !floorShort && ShapeLabel(m) != "" && !f.Demand[m].Sustained && f.Demand[m].Queued == 0 && f.Demand[m].InFlight == 0 {
				continue
			}
			gap := c.Need[m] - c.Ready[m] - c.Future[m]
			if gap <= 0 && !floorShort {
				continue
			}
			victims, ok := autopilotVictims(n, m, cfg)
			if !ok {
				continue
			}
			futureResidents := []string{ModelID(m)}
			for _, old := range n.Residents {
				if !slices.Contains(victims, old) {
					futureResidents = append(futureResidents, old)
				}
			}
			future := NodeContribution(n, futureResidents, c.Workload)
			useful := math.Min(math.Max(0, gap), future[m])
			horizon := math.Min(300, cfg.MinDwell.Seconds())
			benefit := useful * reference[m] * math.Max(0, horizon-fit.LoadSeconds)
			// Actual quality contribution (not chip generation) ranks recipients.
			// The cold load prior and destroyed resident cache impose a switch cost.
			cost := fit.LoadSeconds + float64(len(victims))*cfg.MinBenefitSeconds
			if !fit.Measured {
				cost += cfg.MinBenefitSeconds
			}
			for old, contribution := range c.Contribution[n.ID] {
				cost += contribution * reference[old] * fit.LoadSeconds
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
			if best == nil || (len(victims) == 0 && len(best.Unload) > 0) || ((len(victims) == 0) == (len(best.Unload) == 0) && (benefit > best.Benefit || (benefit == best.Benefit && n.ID < best.Node.ID))) {
				reason := "demand"
				if bootstrap {
					reason = "bootstrap"
				} else if floorShort {
					reason = "protected_floor"
				}
				best = &Action{Workload: m, Reason: reason, Node: n, Load: ModelID(m), Unload: victims, Benefit: benefit, Future: future}
			}
		}
	}
	if best != nil || !cfg.AllowIdleUnload {
		return best
	}
	for _, n := range f.Nodes {
		if !n.Managed || !n.Idle || n.Pending || n.State == nil || !finiteNonnegative(n.MemoryPressure) || !autopilotDonorsProtected(f, c, n) {
			continue
		}
		var victims []string
		for _, m := range n.State.ResidentModels {
			d := demandForModel(f.Demand, m.ModelID)
			if d.Rate > 0 || (!d.LastDemand.IsZero() && now.Sub(d.LastDemand) < cfg.IdleUnloadAfter) || slices.Contains(n.State.PinnedModels, m.ModelID) || m.ResidentSeconds < math.Max(cfg.MinDwell.Seconds(), float64(n.State.MinDwellSeconds)) || m.IdleSeconds < math.Max(cfg.IdleUnloadAfter.Seconds(), float64(n.State.MinIdleSeconds)) {
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
			return &Action{Reason: "idle_surplus", Node: n, Unload: victims, Future: NodeContribution(n, retained, c.Workload)}
		}
	}
	return nil
}

// One fixed valuation per model prevents slow recipients from being rewarded
// for taking longer to serve an identical request. Candidate-specific speed
// enters Rate, never the value assigned to a recovered request.
func autopilotReferenceService(f Fleet, model string) float64 {
	if s := f.Demand[model].ServiceSeconds; finiteNonnegative(s) && s > 0 {
		return s
	}
	var values []float64
	for _, n := range f.Nodes {
		if fit, ok := n.Fits[model]; ok && fit.MeetsDeadline && finiteNonnegative(fit.ServiceSeconds) && fit.ServiceSeconds > 0 {
			values = append(values, fit.ServiceSeconds)
		}
	}
	if len(values) == 0 {
		return 10
	}
	slices.Sort(values)
	return values[len(values)/2]
}

func autopilotVictims(n Node, model string, cfg Config) ([]string, bool) {
	return residency.SelectVictims(n.State, n.Residents, n.Fits[model].WeightsGiB, cfg.MinDwell)
}
