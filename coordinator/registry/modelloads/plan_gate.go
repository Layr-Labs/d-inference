package modelloads

import (
	"sync"
	"time"
)

// PlanGate is the fleet-wide rate limiter. The zero value is ready.
type PlanGate struct {
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

// Claim reports whether a plan may run at now, and records it if so. When it
// refuses, wait is the time left until the window reopens.
func (g *PlanGate) Claim(now time.Time) (ok bool, wait time.Duration) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if !g.last.IsZero() {
		if elapsed := now.Sub(g.last); elapsed < PlanInterval {
			return false, PlanInterval - elapsed
		}
	}
	g.last = now
	g.runs++
	return true, 0
}

// ArmTrailing schedules fn once, wait from now, unless a trailing plan is
// already armed; it reports whether it armed one. The armed flag is cleared
// before fn runs, so a heartbeat refused while the trailing plan is running
// arms the next one rather than being lost.
func (g *PlanGate) ArmTrailing(wait time.Duration, fn func()) bool {
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

// Runs returns how many plans the gate has admitted (tests).
func (g *PlanGate) Runs() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.runs
}

// TrailingArmed reports whether a trailing plan is pending (tests).
func (g *PlanGate) TrailingArmed() bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.trailing
}

// PlanClock binds timer scheduling and callback observation before use. Nil
// functions preserve time.AfterFunc and time.Now; the zero gate is ready.
type PlanClock struct {
	AfterFunc func(time.Duration, func())
	Now       func() time.Time
}

func NewPlanGate(clock PlanClock) PlanGate {
	return PlanGate{afterFunc: clock.AfterFunc, now: clock.Now}
}

func (g *PlanGate) Now() time.Time {
	now := time.Now
	if g.now != nil {
		now = g.now
	}
	return now()
}

func (g *PlanGate) Last() time.Time {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.last
}
