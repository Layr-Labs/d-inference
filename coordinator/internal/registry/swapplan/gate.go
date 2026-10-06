package swapplan

import (
	"sync"
	"time"
)

const Interval = 250 * time.Millisecond

// Claims serializes fleet-wide planning windows and one trailing notification.
type Claims interface {
	Claim(time.Time) (bool, time.Duration)
	ArmTrailing(time.Duration, func()) bool
}

type Gate struct {
	mu       sync.Mutex
	last     time.Time
	trailing bool
	after    func(time.Duration, func())
}

func NewGate(after func(time.Duration, func())) *Gate { return &Gate{after: after} }

func (g *Gate) Claim(now time.Time) (bool, time.Duration) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if !g.last.IsZero() {
		if elapsed := now.Sub(g.last); elapsed < Interval {
			return false, Interval - elapsed
		}
	}
	g.last = now
	return true, 0
}

func (g *Gate) ArmTrailing(wait time.Duration, fn func()) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.trailing {
		return false
	}
	g.trailing = true
	after := g.after
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
