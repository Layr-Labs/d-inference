package fleet

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func WarmPoolFields(snap registry.WarmPoolSnapshot) map[string]any {
	fields := map[string]any{
		"model":                 snap.Model,
		"target_warm":           snap.TargetWarm,
		"warm":                  snap.WarmProviders,
		"eligible_cold":         snap.EligibleCold,
		"cold_ineligible":       snap.ColdIneligible,
		"warm_saturated":        snap.WarmSaturated,
		"warm_foreign_blocked":  snap.WarmForeignBlocked,
		"occupancy_ramp":        snap.OccupancyRamp,
		"headroom_providers":    snap.HeadroomProviders,
		"running":               snap.RunningRequests,
		"waiting":               snap.WaitingRequests,
		"queue_depth":           snap.QueueDepth,
		"oldest_queue_age_ms":   snap.OldestQueueAge.Milliseconds(),
		"spill_arrival_rate":    snap.SpillArrivalRate,
		"service_time_ms":       snap.ServiceTime.Milliseconds(),
		"quality_concurrency":   snap.QualityConcurrency,
		"demand_concurrency":    snap.DemandConcurrency,
		"capacity_rejects":      snap.CapacityRejects,
		"ttft_misses":           snap.TTFTMisses,
		"speculative_started":   snap.SpeculativeStarted,
		"speculative_won":       snap.SpeculativeWon,
		"cold_dispatches":       snap.ColdDispatches,
		"load_duration_ewma_ms": snap.LoadDurationEWMA.Milliseconds(),
		"actions":               len(snap.Actions),
		"observe_only":          snap.ObserveOnly,
	}
	for reason, count := range snap.ColdDisqualifiers {
		fields["cold_disq_"+reason] = count
	}
	return fields
}
