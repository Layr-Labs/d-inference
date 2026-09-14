package faultstate

// rawGateForKey returns the gate filed under key in the index WITHOUT
// following a migration forward — nil when no gate is filed there. Use it to
// assert that an old identity's state did (or did not) leave residue.
func rawGateForKey(r *testManager, key string) *gateState {
	r.gatesMu.RLock()
	defer r.gatesMu.RUnlock()
	return r.gates[key]
}

// withGateForKey runs fn on the gate for key (created on first use) under its
// lock and republishes the lock-free view afterwards, so a direct field poke
// is immediately visible to the routing reads. It does NOT stamp touched (a
// test that backdates a gate's activity keeps its backdate); use the real
// recorders to model activity.
func withGateForKey(r *testManager, key string, fn func(g *gateState)) {
	hold := r.lockGate(r.gateForKey(key), "test")
	fn(hold.g)
	hold.g.publishLocked()
	hold.unlock()
}

// withGateForSession is withGateForKey resolving a session id the way the
// recorders do (bound identity → disconnect cache → session id).
func withGateForSession(r *testManager, sessionID string, fn func(g *gateState)) {
	hold := r.lockGate(r.gateForSession(sessionID), "test")
	fn(hold.g)
	hold.g.publishLocked()
	hold.unlock()
}

// readGateForKey runs fn on the gate filed under key under its lock. fn
// receives nil when the identity has no gate (so callers can assert absence).
func readGateForKey(r *testManager, key string, fn func(g *gateState)) {
	g := r.lookupGateForKey(key)
	if g == nil {
		fn(nil)
		return
	}
	g = g.lockResolved()
	fn(g)
	g.mu.Unlock()
}

// readGateForSession is readGateForKey resolving a session id.
func readGateForSession(r *testManager, sessionID string, fn func(g *gateState)) {
	g := r.lookupGateForSession(sessionID)
	if g == nil {
		fn(nil)
		return
	}
	g = g.lockResolved()
	fn(g)
	g.mu.Unlock()
}

// gateHasBreakerWindow reports whether the identity filed under key has a
// node-health ring (the old providerOutcomes[key] presence check).
func gateHasBreakerWindow(r *testManager, key string) bool {
	g := rawGateForKey(r, key)
	if g == nil {
		return false
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.outcomes != nil
}
