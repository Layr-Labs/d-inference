package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
)

// The projection lock brackets directory attach/detach so provider snapshots
// cannot observe a half-published live binding or a missing disconnect redirect.
func (r *Registry) attachSessionGate(p *Provider) {
	r.sessionsMu.Lock()
	defer r.sessionsMu.Unlock()
	p.gateSession = r.gates.Attach(p.ID)
	if r.sessions == nil {
		r.sessions = make(map[string]*Provider)
	}
	r.sessions[p.ID] = p
}

func (r *Registry) detachSessionGate(p *Provider, stableID string) {
	r.sessionsMu.Lock()
	defer r.sessionsMu.Unlock()
	r.gates.Detach(p.gateSession, stableID)
	delete(r.sessions, p.ID)
}

func (r *Registry) sessionProvider(id string) *Provider {
	r.sessionsMu.RLock()
	p := r.sessions[id]
	r.sessionsMu.RUnlock()
	return p
}

func (r *Registry) gateOf(p *Provider) gateRead {
	if p == nil {
		return gateRead{}
	}
	return gateRead{r.gates.ViewForSession(p.gateSession, p.ID)}
}

func (r *Registry) lookupGateForSession(id string) gateRead {
	return gateRead{r.gates.ViewForSession(nil, id)}
}

func (r *Registry) sweepGates(now time.Time) { r.gates.Sweep(now) }
func (r *Registry) SetGateWaitObserver(fn func(string, time.Duration)) {
	r.gates.SetGateWaitObserver(fn)
}

// These adapters retain the scheduler's private vocabulary without exposing an
// identity's mutable state. A copied read still confirms against its live binding.
type gateRead struct{ view identitygate.View }

func (g gateRead) breakerOpenAt(now int64) bool              { return g.view.BreakerOpenAt(now) }
func (g gateRead) ejectionOpenFor(id string, now int64) bool { return g.view.EjectionOpenFor(id, now) }
func (g gateRead) dispatchLoadCooled(model string, now time.Time) bool {
	return g.view.DispatchLoadCooled(model, now)
}
func (g gateRead) inferenceErrorCooled(model, shape string, now time.Time) bool {
	return g.view.InferenceErrorCooled(model, shape, now)
}
func (g gateRead) capacityCooled(model string, now time.Time) bool {
	return g.view.CapacityCooled(model, now)
}
func (g gateRead) capacityRatePenalty(model string, now time.Time) (float64, float64) {
	return g.view.CapacityRatePenalty(model, now)
}
func (g gateRead) budgetClampActive(model string, heartbeat time.Time, remaining int64, reported bool, now time.Time) bool {
	return g.view.BudgetClampActive(model, heartbeat, remaining, reported, now)
}

type gateView struct {
	p *Provider
	g gateRead
}

func (r *Registry) gateViewOf(p *Provider) gateView { return gateView{p: p, g: r.gateOf(p)} }
func (v *gateView) moved() bool                     { return v.g.view.Confirm() }
