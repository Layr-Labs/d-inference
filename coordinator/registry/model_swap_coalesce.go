package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/modelloads"
)

// model_swap_coalesce.go — fleet-wide coalescing of heartbeat-triggered
// model-swap planning.
//
// Heartbeat used to call TriggerModelSwaps on EVERY heartbeat while the
// request queue was non-empty. The planner walks the fleet per queued model
// (warm scan + cold-candidate scan), so with one queued model no provider
// could serve, every one of ~250 heartbeats/s paid the whole plan (~80 µs at
// 1,260 providers) — ~9% of a core per queued model, in exactly the
// congested regime the 2026-09-01 collapse lived in. The plan's inputs (the
// queued-model set and the fleet's warm/cold state) change on the order of
// seconds, so N heartbeats inside a short window need one plan, not N.
//
// Coalesced is not dropped. A heartbeat the window refuses may be the one
// that made a cold provider loadable (free_for_load_gb grew, a slot reported
// room to reload), and in a small or synchronized fleet the next heartbeat
// can be seconds away — event heartbeats routinely land within a few ms of
// the baseline one. The first refused heartbeat of a window therefore arms
// ONE trailing plan for the window's end, so a state change waits at most
// modelSwapPlanInterval for the planner, never for the next heartbeat. The
// trailing plan claims the gate like any other, so the bound of one plan per
// window still holds.
//
// The queue DRAIN is deliberately NOT coalesced: it is per-heartbeat and
// per-provider (only the heartbeating provider's advertised models), so a
// heartbeat that makes a queued model servable still hands the request over
// immediately — and with the per-model provider index its reservation scan is
// cheap (BenchmarkFleetTickHeartbeatQueuedColdAdvertised).

const modelSwapPlanInterval = modelloads.PlanInterval

// triggerModelSwapsFromHeartbeat is Heartbeat's entry to the swap planner:
// nothing to do while the queue is empty (one queue-lock probe, no
// allocation), otherwise at most one TriggerModelSwaps per
// modelSwapPlanInterval across all heartbeats, a refused heartbeat arming
// the window's trailing plan. Returns whether a plan ran.
func (r *Registry) triggerModelSwapsFromHeartbeat(now time.Time) bool {
	queue := r.Queue()
	if queue == nil || !queue.HasQueued() {
		return false
	}
	ok, wait := r.swapPlanGate.Claim(now)
	if !ok {
		r.swapPlanGate.ArmTrailing(wait, r.trailingModelSwapPlan)
		return false
	}
	r.TriggerModelSwaps()
	return true
}

// trailingModelSwapPlan retries the same gate using the current clock. If a
// heartbeat opened a newer window before this callback ran, another suppressed
// heartbeat may already have changed state while the old timer was armed. Keep
// that notification by rearming for the new window rather than dropping it.
func (r *Registry) trailingModelSwapPlan() {
	r.triggerModelSwapsFromHeartbeat(r.swapPlanGate.Now())
}
