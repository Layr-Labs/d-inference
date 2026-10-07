package utilization

import (
	"math"
	"time"
)

// Compute joins capacity and warm-pool observations. fleet carries the
// provider-deduped throughput and token budget; per-model token budgets in caps
// are used only for the per-model rows and the bottleneck, never summed
// network-wide (that would double-count multi-model providers).
func Compute(caps []ModelCapacity, snaps []WarmPoolSnapshot, fleet FleetCapacity, snapAt, now time.Time) NetworkUtilization {
	bySnap := make(map[string]WarmPoolSnapshot, len(snaps))
	for _, s := range snaps {
		bySnap[s.Model] = s
	}

	out := NetworkUtilization{
		GeneratedAt: now,
		Models:      make([]ModelUtilization, 0, len(caps)),
	}
	out.HasWarmPoolData = len(snaps) > 0
	if out.HasWarmPoolData && !snapAt.IsZero() {
		if age := now.Sub(snapAt).Seconds(); age >= 0 {
			out.WarmDataAgeSecs = age
		}
	}

	var sumDemand, sumServing float64

	for _, c := range caps {
		mu := ModelUtilization{
			Model:            c.ModelID,
			WarmProviders:    c.WarmProviders,
			RunningProviders: c.RunningProviders,
			ColdProviders:    c.ColdProviders,
			ActiveRequests:   c.ActiveRequests,
			QueuedRequests:   c.QueuedRequests,
			AggregateTPS:     c.AggregateTPS,
			TokenBudgetTotal: c.TokenBudgetTotal,
		}

		// Token-budget axis (per-model row only). The network-wide aggregate is
		// taken from the provider-deduped fleet figures below, not summed across
		// model rows, so multi-slot providers aren't double-counted.
		if c.TokenBudgetTotal > 0 {
			used := c.TokenBudgetTotal - c.TokenBudgetRemaining
			if used < 0 {
				used = 0
			}
			mu.TokenBudgetUsed = used
			mu.TokenBudgetUtilization = clamp01(float64(used) / float64(c.TokenBudgetTotal))
		}

		// Warm serving-capacity axis (Little's Law), if the controller has data.
		if s, ok := bySnap[c.ModelID]; ok {
			mu.HasWarmData = true
			mu.DemandConcurrency = nonNeg(s.DemandConcurrency)
			mu.QualityConcurrency = s.QualityConcurrency
			mu.TargetWarm = s.TargetWarm
			mu.SpillArrivalRate = nonNeg(s.SpillArrivalRate)
			// Prefer the warm-pool snapshot's warm count so numerator and
			// denominator come from the same observation; fall back to the
			// capacity snapshot when the controller reports none.
			warm := s.WarmProviders
			if warm <= 0 {
				warm = c.WarmProviders
			}
			// Report the same warm count used to derive ServingCapacity so a
			// drill-down consumer can reproduce serving = warm × quality.
			mu.WarmProviders = warm
			serving := float64(warm) * float64(s.QualityConcurrency)
			mu.ServingCapacity = serving
			switch {
			case serving > 0:
				mu.WarmUtilization = mu.DemandConcurrency / serving
			case mu.DemandConcurrency > 0:
				// Demand with no warm serving capacity (fully cold model with
				// queued/spilled demand) is saturated, not idle.
				mu.WarmUtilization = 1
			}
			sumDemand += mu.DemandConcurrency
			sumServing += serving
			out.SpillArrivalRate += mu.SpillArrivalRate
		}

		// Per-model headline: the bottleneck across axes, clamped.
		mu.Utilization = clamp01(math.Max(mu.WarmUtilization, mu.TokenBudgetUtilization))
		if mu.Utilization > out.BottleneckUtilization {
			out.BottleneckUtilization = mu.Utilization
			out.BottleneckModel = c.ModelID
		}

		// ActiveRequests/QueuedRequests are per-model (each request belongs to
		// one model) so summing them does not double-count.
		out.ActiveRequests += c.ActiveRequests
		out.QueuedRequests += c.QueuedRequests
		out.Models = append(out.Models, mu)
	}

	// Network-wide throughput and token budget come from the provider-deduped
	// fleet figures, NOT from summing per-model rows (which over-counts any
	// provider advertising more than one model).
	out.CapacityTPS = nonNeg(fleet.DecodeTPS)
	out.DemandConcurrency = sumDemand
	out.ServingCapacity = sumServing
	switch {
	case sumServing > 0:
		out.WarmUtilization = sumDemand / sumServing
	case sumDemand > 0:
		// Demand network-wide with no warm serving capacity (whole fleet cold
		// while a burst arrives) is saturated, not idle — mirror the per-model
		// rule so the headline doesn't read 0% during a cold-start storm.
		out.WarmUtilization = 1
	}
	if fleet.BudgetTotal > 0 {
		used := fleet.BudgetUsed
		if used < 0 {
			used = 0
		}
		out.TokenBudgetUtilization = clamp01(float64(used) / float64(fleet.BudgetTotal))
	}
	// Headline: the binding axis network-wide (max of the two aggregates), clamped.
	out.Utilization = clamp01(math.Max(out.WarmUtilization, out.TokenBudgetUtilization))
	return out
}

func clamp01(v float64) float64 {
	if math.IsNaN(v) || v <= 0 {
		return 0
	}
	if v >= 1 {
		return 1
	}
	return v
}

func nonNeg(v float64) float64 {
	if math.IsNaN(v) || v < 0 {
		return 0
	}
	return v
}
