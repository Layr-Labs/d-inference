package autopilot

import (
	"math"
	"slices"
)

type CoverageView struct {
	Ready, Future, Need map[string]float64
	Warm                map[string]int
	Contribution        map[string]map[string]float64
	Reference           map[string]float64
	Workload            map[string]DemandView
}

// A shared GPU contributes at most one machine's execution time. Residency is
// not independent compute. Unqualified resident work can consume time, but it
// must not receive useful capacity credit or hide a deadline-qualified deficit.
func NodeContribution(n Node, residents []string, demand map[string]DemandView) map[string]float64 {
	out := make(map[string]float64)
	if n.UnscopedBusy {
		return out
	}
	weights := make(map[string]float64)
	total := 0.0
	for model, fit := range n.Fits {
		if !slices.Contains(residents, ModelID(model)) {
			continue
		}
		if !finiteNonnegative(fit.Rate) || fit.Rate <= 0 {
			continue
		}
		rate := demand[model].Rate
		if !finiteNonnegative(rate) {
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
	if total > 0 && finiteNonnegative(total) {
		for model, weight := range weights {
			if n.Fits[model].MeetsDeadline {
				out[model] = n.Fits[model].Rate * weight / total
			}
		}
	}
	return out
}

func Coverage(f Fleet) CoverageView {
	c := CoverageView{
		Ready: map[string]float64{}, Future: map[string]float64{}, Need: map[string]float64{},
		Warm: map[string]int{}, Contribution: map[string]map[string]float64{},
		Reference: map[string]float64{}, Workload: map[string]DemandView{},
	}
	// Resolve once per model, not once per node/model (the fallback scans the
	// fleet). One reference prices the same recovered work on every recipient.
	models := make(map[string]bool)
	for m := range f.Demand {
		models[m] = true
	}
	for m := range f.Floors {
		if !hasDemandForModel(f.Demand, m) {
			models[m] = true
		}
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
		if !finiteNonnegative(rate) {
			rate = 0
		}
		// Occupancy and offered-work estimates overlap. Use max, NEVER sum.
		// Include occupancy-only models whose first logical terminal has not
		// arrived yet, both in demand and in shared-GPU time allocation.
		live := max(0, d.InFlight) + max(0, d.Queued)
		c.Need[m] = math.Max(rate, float64(live)/c.Reference[m])
		d.Rate = c.Need[m]
		c.Workload[m] = d
	}
	for _, node := range f.Nodes {
		if node.Pending {
			future := node.Future
			if node.FutureResidents != nil {
				future = NodeContribution(node, node.FutureResidents, c.Workload)
			}
			for m, rate := range future {
				if finiteNonnegative(rate) {
					c.Future[m] += rate
				}
			}
			continue
		}
		contribution := NodeContribution(node, node.Residents, c.Workload)
		c.Contribution[node.ID] = contribution
		for _, model := range node.Residents {
			if autopilotQualifiedResident(node, model) {
				c.Warm[model]++
			}
		}
		for model, rate := range contribution {
			c.Ready[model] += rate

		}
	}
	return c
}

func floor(f Fleet, model string) int {
	floor := max(0, f.Floors[model])
	d := demandForModel(f.Demand, model)
	if d.Rate > 0 && (d.Requests >= 3 || d.CapacityShed > 0) {
		floor = max(1, floor)
	}
	return floor
}

func autopilotDonorsProtected(f Fleet, c CoverageView, n Node) bool {
	// Loading fences the entire device, including retained co-residents. Debit
	// every contribution for the whole transition; future capacity cannot protect
	// a currently needed donor. Other commands are already absent from Ready.
	for _, model := range n.Residents {
		if autopilotQualifiedResident(n, model) && c.Warm[model]-1 < floor(f, model) {
			return false
		}
	}
	for cohort, contribution := range c.Contribution[n.ID] {
		if c.Ready[cohort]-contribution+1e-9 < c.Need[cohort] {
			return false
		}
	}

	return true
}

func autopilotQualifiedResident(n Node, model string) bool {
	for key, fit := range n.Fits {
		if ModelID(key) == model && fit.MeetsDeadline && fit.Rate > 0 {
			return true
		}
	}
	return false
}
