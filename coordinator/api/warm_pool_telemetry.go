package api

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Poll more frequently than the default 30-second controller interval so the
// emitter observes periodic ticks without depending on startup ordering. The
// snapshot timestamp suppresses duplicates and bounds volume when the
// controller is idle.
const warmPoolTelemetryPollInterval = 15 * time.Second

// StartWarmPoolTelemetryLoop forwards the latest distinct warm-pool planning
// snapshot to the coordinator telemetry emitter. The registry keeps only the
// newest tick, so this is a sampled state feed rather than an event ledger.
func (s *Server) StartWarmPoolTelemetryLoop(ctx context.Context) {
	if s == nil || s.registry == nil || s.emitter == nil || s.dd == nil {
		return
	}

	var lastEmittedAt time.Time
	emitLatest := func() {
		snaps, at := s.registry.LatestWarmPoolSnapshots()
		if len(snaps) == 0 || at.IsZero() || !at.After(lastEmittedAt) {
			return
		}
		for _, snap := range snaps {
			s.emit(ctx, protocol.SeverityInfo, protocol.KindCustom, "warm_pool_tick",
				warmPoolTelemetryFields(snap))
		}
		lastEmittedAt = at
	}

	emitLatest()
	ticker := time.NewTicker(warmPoolTelemetryPollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			emitLatest()
		}
	}
}

func warmPoolTelemetryFields(snap registry.WarmPoolSnapshot) map[string]any {
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
