package autopilot

import (
	"slices"
	"time"
)

func Summarize(f Fleet, cfg Config, now time.Time) Summary {
	s := Summary{At: now, ObserveOnly: cfg.ObserveOnly, Excluded: f.Excluded}
	coverage := Coverage(f)
	models := make([]string, 0, len(f.Demand)+len(f.Floors))
	for m := range f.Demand {
		models = append(models, m)
	}
	for m := range f.Floors {
		if !slices.Contains(models, m) {
			models = append(models, m)
		}
	}
	slices.Sort(models)
	for _, n := range f.Nodes {
		if n.Managed {
			s.OptedIn++
		}
		if n.Pending {
			s.Pending++
			if n.Uncertain {
				s.Uncertain++
			}
		}
	}
	for _, m := range models {
		eligible := 0
		for _, n := range f.Nodes {
			if n.Managed && n.Idle && !n.Pending && n.Fits[m].MeetsDeadline {
				eligible++
			}
		}
		s.Models = append(s.Models, ModelSummary{Model: ModelID(m), Shape: ShapeLabel(m), LogicalRequests: f.Demand[m].Requests, QueuedRequests: f.Demand[m].Queued, InFlightRequests: f.Demand[m].InFlight, OfferedRPS: f.Demand[m].Rate, CapacityRPS: coverage.Ready[m], PendingRPS: coverage.Future[m], ProtectedFloor: floor(f, ModelID(m)), WarmProviders: coverage.Warm[ModelID(m)], EligibleIdle: eligible, DeficitRPS: max(0, coverage.Need[m]-coverage.Ready[m]-coverage.Future[m])})
	}
	return s
}
