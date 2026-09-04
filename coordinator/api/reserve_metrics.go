package api

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// reserve_metrics.go — DogStatsD series for the reservation path's lock and
// scan cost. The registry has no metrics client, so it exposes counters
// (registry/lock_metrics.go) and this file turns them into series:
//
//	registry.mu.writers_waiting        gauge  writers parked on Registry.mu now
//	registry.mu.lock_wait_ms{stat}     gauge  writer wait mean / p50 / p99 / max
//	registry.mu.lock_acquisitions      count  exclusive acquisitions per tick
//	routing.fleet_walks                count  full-fleet provider walks per tick
//	routing.reserve_rescans{model}     hist   discarded reserve iterations/request
//	routing.reserve_rescan_us{model}   hist   time those iterations cost
//	routing.in_gap_pending_candidates{model} hist candidates charged for
//	                                   coordinator pending the heartbeat had
//	                                   not yet reported (exposure sizing)
//	dispatch_plan.skip{reason}         count  plan entries passed over, by reason
//	dispatch_plan.entries_consumed     hist   entries consumed when a plan exhausts
//	routing.hedge_governor_snapshot{model} count governor fleet snapshots taken
//
// The writer-wait series are the pass/fail instrument for the Registry.mu
// work (recorders off the write lock, commit rescan bound): the target after
// it lands is writer p99 < 50 ms with writers_waiting at 0-2.

// reserveMetricsState carries the last-seen cumulative counters so the gauge
// loop can emit per-tick deltas. Written by the gauge-loop goroutine only.
type reserveMetricsState struct {
	fleetWalks int64
}

// emitReserveDecisionMetrics emits the per-request reserve-loop series. Called
// once per reservation on the dispatch goroutine, right after the decision is
// stamped onto the attempt profile.
func (s *Server) emitReserveDecisionMetrics(model string, d registry.RoutingDecision) {
	if s.dd == nil {
		return
	}
	tags := []string{"model:" + model}
	s.ddHistogram("routing.reserve_rescans", float64(d.Rescans), tags)
	if d.Rescans > 0 {
		s.ddHistogram("routing.reserve_rescan_us", float64(d.RescanUS), tags)
	}
	s.ddHistogram("routing.in_gap_pending_candidates", float64(d.InGapPendingCandidates), tags)
}

// notePlanSkips emits one dispatch_plan.skip per passed-over plan entry
// (bounded PlanSkipReason vocabulary, so the tag is cardinality-safe) and, on
// exhaustion, how many entries the plan served before running dry.
func (s *Server) notePlanSkips(plan *registry.DispatchPlan, skips []registry.PlanSkip) {
	if s.dd == nil {
		return
	}
	for _, skip := range skips {
		s.ddIncr("dispatch_plan.skip", []string{"reason:" + string(skip.Reason)})
		if skip.Reason == registry.PlanSkipExhausted && plan != nil {
			s.ddHistogram("dispatch_plan.entries_consumed", float64(plan.Len()-plan.Remaining()), nil)
		}
	}
}

// emitRegistryLockGauges pushes the Registry.mu writer-wait window and the
// fleet-walk deltas. Called from StartDDGaugeLoop every 15 s; it is the one
// consumer that resets the lock-wait window.
func (s *Server) emitRegistryLockGauges() {
	if s.dd == nil || s.registry == nil {
		return
	}
	lw := s.registry.LockWaitSnapshot()
	s.ddGauge("registry.mu.writers_waiting", float64(lw.WritersWaiting), nil)
	s.ddCount("registry.mu.lock_acquisitions", lw.Count, nil)
	if lw.Count > 0 {
		s.ddGauge("registry.mu.lock_wait_ms", float64(lw.MeanUS)/1000, []string{"stat:mean"})
		s.ddGauge("registry.mu.lock_wait_ms", float64(lw.P50US)/1000, []string{"stat:p50"})
		s.ddGauge("registry.mu.lock_wait_ms", float64(lw.P99US)/1000, []string{"stat:p99"})
		s.ddGauge("registry.mu.lock_wait_ms", float64(lw.MaxUS)/1000, []string{"stat:max"})
	}
	walks := s.registry.FleetWalkCount()
	s.ddCount("routing.fleet_walks", walks-s.reserveMetrics.fleetWalks, nil)
	s.reserveMetrics.fleetWalks = walks
}
