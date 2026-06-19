package registry

import (
	"math"
	"time"
)

// utilization.go computes a network-utilization summary for the fleet.
//
// "Utilization" in an LLM-serving network is an offered-load ratio,
// demand / capacity, evaluated per binding resource. Two axes matter:
//
//  1. Warm serving capacity (compute, Little's Law). The warm-pool controller
//     already derives demand concurrency L = λ·E[S] and the per-provider quality
//     concurrency (the largest batch that keeps every request decoding above the
//     quality floor). Serving capacity = warm_providers × quality_concurrency, so
//     warm utilization = L / serving_capacity. This is the axis that actually
//     binds in practice: requests are shed (ttft_too_slow / capacity_reject) when
//     no warm provider has headroom, long before raw memory is exhausted.
//
//  2. Token budget (KV-cache memory). Aggregate used / total token budget across
//     providers, from the capacity snapshot.
//
// The headline figure is the capacity-weighted aggregate of the binding axis,
// clamped to [0,1]; the raw uncapped ratios, the bottleneck (hottest) model, and
// a per-model breakdown are included for drill-down. The instantaneous spill
// arrival rate is carried alongside so callers can see demand the network is
// currently rejecting (utilization saturates at 1, but demand can exceed it).

// ModelUtilization is the per-model utilization breakdown across both axes.
type ModelUtilization struct {
	Model string `json:"model"`

	// Headline for this model: the bottleneck across axes, clamped to [0,1].
	Utilization float64 `json:"utilization"`

	// Warm serving-capacity axis (Little's Law).
	WarmUtilization    float64 `json:"warm_utilization"` // demand / serving_capacity (uncapped)
	DemandConcurrency  float64 `json:"demand_concurrency"`
	ServingCapacity    float64 `json:"serving_capacity"`
	WarmProviders      int     `json:"warm_providers"`
	TargetWarm         int     `json:"target_warm"`
	QualityConcurrency int     `json:"quality_concurrency"`
	SpillArrivalRate   float64 `json:"spill_arrival_rate"` // EWMA req/s currently shed at quality
	HasWarmData        bool    `json:"has_warm_data"`

	// Token-budget (KV-cache memory) axis.
	TokenBudgetUtilization float64 `json:"token_budget_utilization"`
	TokenBudgetUsed        int64   `json:"token_budget_used"`
	TokenBudgetTotal       int64   `json:"token_budget_total"`

	// Occupancy (informational).
	ActiveRequests   int     `json:"active_requests"`
	QueuedRequests   int     `json:"queued_requests"`
	RunningProviders int     `json:"running_providers"`
	ColdProviders    int     `json:"cold_providers"`
	AggregateTPS     float64 `json:"aggregate_tps"`
}

// NetworkUtilization is the fleet-wide utilization summary.
type NetworkUtilization struct {
	// Utilization is the public headline: capacity-weighted aggregate of the
	// binding axis, clamped to [0,1] (1.0 = fully saturated).
	Utilization float64 `json:"utilization"`

	// Raw aggregates (uncapped) for drill-down.
	WarmUtilization        float64 `json:"warm_utilization"`         // Σdemand / Σserving_capacity
	TokenBudgetUtilization float64 `json:"token_budget_utilization"` // Σused / Σtotal
	BottleneckUtilization  float64 `json:"bottleneck_utilization"`   // max per-model utilization
	BottleneckModel        string  `json:"bottleneck_model,omitempty"`

	DemandConcurrency float64 `json:"demand_concurrency"` // Σ L across models
	ServingCapacity   float64 `json:"serving_capacity"`   // Σ warm×quality across models
	CapacityTPS       float64 `json:"capacity_tps"`       // Σ aggregate decode TPS
	SpillArrivalRate  float64 `json:"spill_arrival_rate"` // Σ req/s shed at quality
	ActiveRequests    int     `json:"active_requests"`
	QueuedRequests    int     `json:"queued_requests"`

	Models          []ModelUtilization `json:"models"`
	GeneratedAt     time.Time          `json:"generated_at"`
	WarmDataAgeSecs float64            `json:"warm_data_age_seconds"` // staleness of warm-pool snapshot (0 = none)
	HasWarmPoolData bool               `json:"has_warm_pool_data"`
}

// PublicNetworkUtilization is the privacy-safe projection served on the
// unauthenticated /v1/stats endpoint. It carries the headline utilization, the
// two axis ratios, the bottleneck, and the already-public aggregate occupancy —
// but deliberately omits the warm-pool control-loop internals (absolute demand /
// serving concurrency, spill arrival rate, target warm, quality concurrency, and
// the per-model breakdown), which stay admin-only via /v1/admin/utilization.
type PublicNetworkUtilization struct {
	Utilization            float64 `json:"utilization"`
	WarmUtilization        float64 `json:"warm_utilization"`
	TokenBudgetUtilization float64 `json:"token_budget_utilization"`
	BottleneckUtilization  float64 `json:"bottleneck_utilization"`
	BottleneckModel        string  `json:"bottleneck_model,omitempty"`
	CapacityTPS            float64 `json:"capacity_tps"`
	ActiveRequests         int     `json:"active_requests"`
	QueuedRequests         int     `json:"queued_requests"`
}

// Public returns the privacy-safe projection of the full snapshot for the public
// stats endpoint.
func (n NetworkUtilization) Public() PublicNetworkUtilization {
	return PublicNetworkUtilization{
		Utilization:            n.Utilization,
		WarmUtilization:        n.WarmUtilization,
		TokenBudgetUtilization: n.TokenBudgetUtilization,
		BottleneckUtilization:  n.BottleneckUtilization,
		BottleneckModel:        n.BottleneckModel,
		CapacityTPS:            n.CapacityTPS,
		ActiveRequests:         n.ActiveRequests,
		QueuedRequests:         n.QueuedRequests,
	}
}

// FleetCapacity is the provider-deduped aggregate throughput and KV/token budget
// of the routable public fleet. It is computed by counting each provider once,
// which avoids the multi-model double-counting that arises from summing
// per-model ModelCapacity rows (a provider advertising N models appears in N
// rows, and slots on one machine share a single memory pool).
type FleetCapacity struct {
	DecodeTPS   float64 // Σ per-provider rated decode tok/s (counted once)
	BudgetUsed  int64   // Σ per-provider used+queued token budget
	BudgetTotal int64   // Σ per-provider token budget (largest slot per provider)
}

// FleetCapacitySnapshot returns the provider-deduped fleet capacity using the
// same public routing gates as ModelCapacitySnapshot. Read-only.
func (r *Registry) FleetCapacitySnapshot() FleetCapacity {
	now := time.Now()
	var fc FleetCapacity
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		p.mu.Lock()
		if !r.publiclyRoutableLocked(p, now) {
			p.mu.Unlock()
			continue
		}
		fc.DecodeTPS += resolvedDecodeTPS(p)
		// Slots on one machine share a single unified-memory pool, so the
		// provider's budget is the largest slot's max (not the sum), while used
		// reservations across its slots do add up (capped at that max).
		if p.BackendCapacity != nil {
			var provMax, provUsed int64
			for _, slot := range p.BackendCapacity.Slots {
				if slot.ActiveTokenBudgetMax > provMax {
					provMax = slot.ActiveTokenBudgetMax
				}
				provUsed += slot.ActiveTokenBudgetUsed + slot.QueuedTokenBudget
			}
			if provUsed > provMax {
				provUsed = provMax
			}
			fc.BudgetTotal += provMax
			fc.BudgetUsed += provUsed
		}
		p.mu.Unlock()
	}
	return fc
}

// NetworkUtilizationSnapshot computes the fleet-wide utilization summary by
// joining the capacity snapshot (warm/cold counts, per-model token budgets) and
// the provider-deduped fleet capacity (throughput, aggregate token budget) with
// the warm-pool controller's last Little's Law diagnostics. It is read-only and
// side-effect free.
func (r *Registry) NetworkUtilizationSnapshot() NetworkUtilization {
	caps := r.ModelCapacitySnapshot()
	snaps, snapAt := r.LatestWarmPoolSnapshots()
	fleet := r.FleetCapacitySnapshot()
	return computeNetworkUtilization(caps, snaps, fleet, snapAt, time.Now())
}

// computeNetworkUtilization is the pure core, split out for unit testing without
// a live Registry. fleet carries the provider-deduped throughput and token
// budget; per-model token budgets in caps are used only for the per-model rows
// and the bottleneck, never summed network-wide (that would double-count
// multi-model providers).
func computeNetworkUtilization(caps []ModelCapacity, snaps []WarmPoolSnapshot, fleet FleetCapacity, snapAt, now time.Time) NetworkUtilization {
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
