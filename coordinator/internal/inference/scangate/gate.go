// Package scangate bounds CPU fleet walks independently of sidecar planning.
package scangate

import "time"

type Result int

const (
	Acquired Result = iota
	Timeout
	ClientGone
)

type Gate struct {
	permits chan struct{}
}

func New(capacity int) *Gate {
	g := &Gate{}
	g.Configure(capacity)
	return g
}

// Configure runs before serving; replacing live permits would strand holders.
func (g *Gate) Configure(capacity int) {
	if capacity < 2 {
		capacity = 2
	}
	g.permits = make(chan struct{}, capacity)
}

func (g *Gate) Acquire(wait time.Duration, done <-chan struct{}) Result {
	if g == nil || g.permits == nil {
		return Acquired
	}
	select {
	case g.permits <- struct{}{}:
		return Acquired
	default:
	}
	clientGone := func() bool {
		select {
		case <-done:
			return true
		default:
			return false
		}
	}
	if wait <= 0 {
		if clientGone() {
			return ClientGone
		}
		return Timeout
	}
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case g.permits <- struct{}{}:
		return Acquired
	case <-timer.C:
		if clientGone() {
			return ClientGone
		}
		return Timeout
	case <-done:
		return ClientGone
	}
}

func (g *Gate) Release() {
	if g != nil && g.permits != nil {
		<-g.permits
	}
}

func (g *Gate) Capacity() int { return cap(g.permits) }
func (g *Gate) InFlight() int { return len(g.permits) }

// PreflightWait keeps admission's overload response short. An already-expired
// positive clock remains positive, so it cannot become an exempt request.
func PreflightWait(deadline time.Duration) time.Duration {
	if deadline <= 0 {
		return 250 * time.Millisecond
	}
	wait := max(time.Nanosecond, deadline/4)
	if wait > time.Second {
		wait = time.Second
	}
	return wait
}
