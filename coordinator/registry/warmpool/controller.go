package warmpool

import (
	"context"
	"time"
)

func (c *Controller[A]) Run(ctx context.Context) {
	interval := c.configuration().Interval
	if interval <= 0 {
		interval = 30 * time.Second
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-c.triggerC:
			c.Tick(time.Now())
		case <-ticker.C:
			c.Tick(time.Now())
		}
	}
}

func (c *Controller[A]) Tick(now time.Time) []Snapshot[A] {
	if c == nil || c.bindings.FleetSnapshot == nil {
		return nil
	}
	c.tickMu.Lock()
	defer c.tickMu.Unlock()
	snapshots := c.Plan(now)
	c.storeSnapshots(snapshots, now)
	for _, snap := range snapshots {
		if c.logger() != nil {
			c.logger().Info("warm_pool_tick",
				"model", snap.Model,
				"target_warm", snap.TargetWarm,
				"warm", snap.WarmProviders,
				"warm_saturated", snap.WarmSaturated,
				"warm_foreign_blocked", snap.WarmForeignBlocked,
				"occupancy_ramp", snap.OccupancyRamp,
				"headroom_providers", snap.HeadroomProviders,
				"eligible_cold", snap.EligibleCold,
				"running", snap.RunningRequests,
				"waiting", snap.WaitingRequests,
				"queue_depth", snap.QueueDepth,
				"oldest_queue_age_ms", snap.OldestQueueAge.Milliseconds(),
				"spill_arrival_rate", snap.SpillArrivalRate,
				"service_time_ms", snap.ServiceTime.Milliseconds(),
				"quality_concurrency", snap.QualityConcurrency,
				"demand_concurrency", snap.DemandConcurrency,
				"capacity_rejects", snap.CapacityRejects,
				"ttft_misses", snap.TTFTMisses,
				"speculative_started", snap.SpeculativeStarted,
				"speculative_won", snap.SpeculativeWon,
				"cold_dispatches", snap.ColdDispatches,
				"actions", len(snap.Actions),
				"observe_only", snap.ObserveOnly,
			)
		}
		if snap.ObserveOnly || len(snap.Actions) == 0 {
			continue
		}
		c.bindings.Send(snap.Actions)
	}
	return snapshots
}
