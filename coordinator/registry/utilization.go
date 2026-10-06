package registry

import (
	"time"

	kvbudget "github.com/eigeninference/d-inference/coordinator/internal/registry/kvbudget"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/utilization"
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
type ModelUtilization = utilization.ModelUtilization

// NetworkUtilization is the fleet-wide utilization summary.
type NetworkUtilization = utilization.NetworkUtilization

// PublicNetworkUtilization is the privacy-safe projection served on the
// unauthenticated /v1/stats endpoint. It carries the headline utilization, the
// two axis ratios, the bottleneck, and the already-public aggregate occupancy —
// but deliberately omits the warm-pool control-loop internals (absolute demand /
// serving concurrency, spill arrival rate, target warm, quality concurrency, and
// the per-model breakdown), which stay admin-only via /v1/admin/utilization.
type PublicNetworkUtilization = utilization.PublicNetworkUtilization

// FleetCapacity is the provider-deduped aggregate throughput and KV/token budget
// of the routable public fleet. It is computed by counting each provider once,
// which avoids the multi-model double-counting that arises from summing
// per-model ModelCapacity rows (a provider advertising N models appears in N
// rows, and slots on one machine draw on a single memory pool).
type FleetCapacity = utilization.FleetCapacity

// FleetCapacitySnapshot returns the provider-deduped fleet capacity using the
// same public routing gates as ModelCapacitySnapshot. Read-only.
func (r *Registry) FleetCapacitySnapshot() FleetCapacity {
	now := time.Now()
	var fc FleetCapacity
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		p.mu.Lock()
		if !r.publiclyRoutableLocked(p, now) ||
			!r.providerServesAnyCatalogModelLocked(p) {
			p.mu.Unlock()
			continue
		}
		fc.DecodeTPS += resolvedDecodeTPS(p)
		// Reconstruct the provider's pooled KV/token budget (Σ private grants).
		if p.BackendCapacity != nil {
			used, total := kvbudget.TokenTotals(p.BackendCapacity.Slots)
			fc.BudgetUsed += used
			fc.BudgetTotal += total
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
	now := time.Now()
	capacity := make([]utilization.ModelCapacity, len(caps))
	for i, c := range caps {
		capacity[i] = utilization.ModelCapacity{
			ModelID:              c.ModelID,
			WarmProviders:        c.WarmProviders,
			RunningProviders:     c.RunningProviders,
			ColdProviders:        c.ColdProviders,
			ActiveRequests:       c.ActiveRequests,
			QueuedRequests:       c.QueuedRequests,
			AggregateTPS:         c.AggregateTPS,
			TokenBudgetTotal:     c.TokenBudgetTotal,
			TokenBudgetRemaining: c.TokenBudgetRemaining,
		}
	}
	warm := make([]utilization.WarmPoolSnapshot, len(snaps))
	for i, s := range snaps {
		warm[i] = utilization.WarmPoolSnapshot{
			Model:              s.Model,
			WarmProviders:      s.WarmProviders,
			QualityConcurrency: s.QualityConcurrency,
			DemandConcurrency:  s.DemandConcurrency,
			TargetWarm:         s.TargetWarm,
			SpillArrivalRate:   s.SpillArrivalRate,
		}
	}
	return utilization.Compute(capacity, warm, fleet, snapAt, now)
}
