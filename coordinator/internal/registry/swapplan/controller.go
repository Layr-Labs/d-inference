package swapplan

import "time"

type Dependencies struct {
	Queued    func() bool
	Plan      func()
	Now       func() time.Time
	AfterFunc func(time.Duration, func())
	Claims    func(*Gate) Claims
}

type Controller struct {
	queued func() bool
	plan   func()
	now    func() time.Time
	claims Claims
}

func New(deps Dependencies) *Controller {
	gate := NewGate(deps.AfterFunc)
	var claims Claims = gate
	if deps.Claims != nil {
		claims = deps.Claims(gate)
	}
	if deps.Now == nil {
		deps.Now = time.Now
	}
	return &Controller{queued: deps.Queued, plan: deps.Plan, now: deps.Now, claims: claims}
}

// Trigger runs one actual planning pass, or remembers the notification until
// the window reopens. A delayed timer reclaims the gate against the current
// clock, preserving any newer heartbeat suppressed while it was armed.
func (c *Controller) Trigger(now time.Time) bool {
	if c == nil || c.queued == nil || !c.queued() {
		return false
	}
	allowed, wait := c.claims.Claim(now)
	if !allowed {
		c.claims.ArmTrailing(wait, func() { c.Trigger(c.now()) })
		return false
	}
	c.plan()
	return true
}
