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
	mu       sync.Mutex
	last     time.Time
	runs     int  // plans admitted (tests)
	trailing bool // a trailing plan is armed for the end of the current window
	// afterFunc schedules the trailing plan; nil means time.AfterFunc. Tests
	// inject a capturing stub so the trailing plan fires deterministically.
	afterFunc func(d time.Duration, f func())
	// now supplies the timer callback clock; nil means time.Now.
	now func() time.Time
}

// claim reports whether a plan may run at now, and records it if so. When it
// refuses, wait is the time left until the window reopens.
func (g *modelSwapPlanGate) claim(now time.Time) (ok bool, wait time.Duration) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if !g.last.IsZero() {
		if elapsed := now.Sub(g.last); elapsed < modelSwapPlanInterval {
			return false, modelSwapPlanInterval - elapsed
		}
	}
	g.last = now
	g.runs++
	return true, 0
}

// armTrailing schedules fn once, wait from now, unless a trailing plan is
// already armed; it reports whether it armed one. The armed flag is cleared
// before fn runs, so a heartbeat refused while the trailing plan is running
// arms the next one rather than being lost.
func (g *modelSwapPlanGate) armTrailing(wait time.Duration, fn func()) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.trailing {
		return false
	}
	g.trailing = true
	after := g.afterFunc
	if after == nil {
		after = func(d time.Duration, f func()) { time.AfterFunc(d, f) }
	}
	after(wait, func() {
		g.mu.Lock()
		g.trailing = false
		g.mu.Unlock()
		fn()
	})
	return true
}

// planRuns returns how many plans the gate has admitted (tests).
func (g *modelSwapPlanGate) planRuns() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.runs
}

// trailingArmed reports whether a trailing plan is pending (tests).
func (g *modelSwapPlanGate) trailingArmed() bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.trailing
}

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
	ok, wait := r.swapPlanGate.claim(now)
	if !ok {
		r.swapPlanGate.armTrailing(wait, r.trailingModelSwapPlan)
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
	now := time.Now
	if r.swapPlanGate.now != nil {
		now = r.swapPlanGate.now
	}
	r.triggerModelSwapsFromHeartbeat(now())
}
