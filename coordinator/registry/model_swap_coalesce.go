package registry

import (
	"sync"
	"time"
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
// The queue DRAIN is deliberately NOT coalesced: it is per-heartbeat and
// per-provider (only the heartbeating provider's advertised models), so a
// heartbeat that makes a queued model servable still hands the request over
// immediately — and with the per-model provider index its reservation scan is
// cheap (BenchmarkFleetTickHeartbeatQueuedColdAdvertised).

// modelSwapPlanInterval is the minimum spacing between heartbeat-triggered
// swap plans, fleet-wide. 250 ms keeps a newly-queued cold model's load_model
// within a quarter second of the next heartbeat (heartbeats arrive every ~4
// ms at fleet scale) while bounding planner CPU to ≤ 4 plans/s regardless of
// fleet size or queue depth. The explicit TriggerModelSwaps entry point
// (api cold-dispatch kick, tests) stays immediate and is not subject to this
// gate. Deliberately a constant, not an env knob.
const modelSwapPlanInterval = 250 * time.Millisecond

// modelSwapPlanGate is the fleet-wide rate limiter. The zero value is ready.
type modelSwapPlanGate struct {
	mu   sync.Mutex
	last time.Time
	runs int // plans admitted (tests)
}

// claim reports whether a plan may run at now, and records it if so.
func (g *modelSwapPlanGate) claim(now time.Time) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if !g.last.IsZero() && now.Sub(g.last) < modelSwapPlanInterval {
		return false
	}
	g.last = now
	g.runs++
	return true
}

// planRuns returns how many plans the gate has admitted (tests).
func (g *modelSwapPlanGate) planRuns() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.runs
}

// triggerModelSwapsFromHeartbeat is Heartbeat's entry to the swap planner:
// nothing to do while the queue is empty (one queue-lock probe, no
// allocation), otherwise at most one TriggerModelSwaps per
// modelSwapPlanInterval across all heartbeats. Returns whether a plan ran.
func (r *Registry) triggerModelSwapsFromHeartbeat(now time.Time) bool {
	queue := r.Queue()
	if queue == nil || !queue.HasQueued() {
		return false
	}
	if !r.swapPlanGate.claim(now) {
		return false
	}
	r.TriggerModelSwaps()
	return true
}
