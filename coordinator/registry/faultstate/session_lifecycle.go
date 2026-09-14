package faultstate

// attachSessionGate files a freshly registered session under its own id and
// caches the gate on the Provider. Called by Register (under r.mu; the order
// r.mu → gatesMu holds).
func (r *Manager[C]) Attach(p *Session[C], connection C, id string) {
	p.id = id
	p.connection = connection
	now := r.now()
	r.gatesMu.Lock()
	defer r.gatesMu.Unlock()
	g := r.ensureGateLocked(p.id, now)
	g.live++
	p.gate.Store(g)
	r.sessions[p.id] = p
}

// detachSessionGate removes a disconnecting session from the index. stableID
// is the identity derived at disconnect: when present it is cached so the
// trailing pending-request flush still resolves the session (its state lives
// on under the identity's gate — FAULT STATE IS NOT CLEARED ON DISCONNECT);
// when absent the session-keyed gate is the only thing that ever referenced
// this identity, so its residue is dropped for hygiene, exactly as the old
// implementation dropped the session-keyed map entries. Called by Disconnect
// (under r.mu and p.mu; the order r.mu → p.mu → gatesMu holds).
func (r *Manager[C]) Detach(p *Session[C], stableID string) {
	r.gatesMu.Lock()
	defer r.gatesMu.Unlock()
	r.gatesInitLocked()
	// Live references and later disconnect-cache lookups must date the same
	// event identically when comparing it with a concurrent version reset.
	disconnectedAt := r.now()
	p.gateDisconnectedAtNS.Store(disconnectedAt.UnixNano())
	delete(r.sessions, p.id)
	g := p.gate.Load()
	if g != nil {
		g.live--
		g.mu.Lock()
		g.touched = disconnectedAt
		g.mu.Unlock()
	}
	if stableID != "" {
		r.rememberDisconnectedStableIDLocked(p.id, stableID, disconnectedAt)
		return
	}
	if g != nil && g.key == p.id && g.live <= 0 && r.gates[p.id] == g {
		delete(r.gates, p.id)
	}
}
