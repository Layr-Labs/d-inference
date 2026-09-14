package registry

import (
	"time"
)

// faultKeyForSession resolves live or trailing disconnected identity through
// faultstate.Manager.FaultKeyForSession; an unbound session keeps its own key.
func (r *Registry) faultKeyForSession(sessionID string) string {
	return r.faults.FaultKeyForSession(sessionID)
}

// sessionProvider returns the live Provider for a session id without touching
// r.mu (the recorders that need a budget snapshot read p.BackendCapacity
// under p.mu). nil when the session is gone.
func (r *Registry) sessionProvider(sessionID string) *Provider {
	return r.faults.Connection(sessionID)
}

// gateCount reports the size of the gate index (tests / observability).
func (r *Registry) gateCount() int {
	return r.faults.Count()
}

// attachSessionGate binds one fresh Session to this exact Provider under r.mu.
// The Session address is stable; faultstate.Manager.Attach publishes its gate.
func (r *Registry) attachSessionGate(p *Provider) {
	r.faults.Attach(&p.faultSession, p, p.ID)
}

// detachSessionGate removes this session under r.mu and p.mu.
// faultstate.Manager.Detach preserves stable-identity history and trailing-flush
// identity; an unbound session leaves no retained history.
func (r *Registry) detachSessionGate(p *Provider, stableID string) {
	r.faults.Detach(&p.faultSession, stableID)
}

// bindStableFaultKey changes the gate binding inside the stable p.faultSession
// while p.mu excludes dispatch-deciding reads. faultstate.Manager.Bind rejects
// retired connections and owns migration/publication order; an empty identity
// unbinds without moving the old identity history.
func (r *Registry) bindStableFaultKey(p *Provider, stableID string) {
	if p == nil {
		return
	}
	r.faults.Bind(&p.faultSession, stableID, p.Version)
}

// sweepGates delegates eviction-loop pruning and retirement to faultstate.Manager.Sweep.
func (r *Registry) sweepGates(now time.Time) {
	r.faults.Sweep(now)
}

// SetGateWaitObserver binds the recorder wait observer through
// faultstate.Manager.SetGateWaitObserver. Notifications occur after gate release;
// startup supplies the observer and nil clears it.
func (r *Registry) SetGateWaitObserver(fn func(site string, wait time.Duration)) {
	r.faults.SetGateWaitObserver(fn)
}

// HoldGateForTest delegates a test-only gate hold to faultstate.Manager.HoldGateForTest.
func (r *Registry) HoldGateForTest(providerID string) (release func()) {
	return r.faults.HoldGateForTest(providerID)
}

// SetVersion updates the live provider version under p.mu.
// faultstate.Manager.NoteVersion checks the exact session generation before
// observing version history on its current gate.
func (p *Provider) SetVersion(version string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.Version = version
	r := p.registry
	if r == nil || version == "" {
		return
	}
	r.faults.NoteVersion(&p.faultSession, version)
}
