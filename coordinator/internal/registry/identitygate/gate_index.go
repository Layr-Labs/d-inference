package identitygate

import "time"

// gatesInit lazily creates the gate index so bare &Registry{} test
// constructions work without New(). Caller holds gatesMu for writing.
func (r *Directory) gatesInitLocked() {
	if r.gates == nil {
		r.gates = make(map[string]*State)
	}
	if r.sessions == nil {
		r.sessions = make(map[string]*Session)
	}
	if r.disconnectedStableIDs == nil {
		r.disconnectedStableIDs = make(map[string]disconnectedStableID)
	}
}

// ensureGateLocked returns the gate for key, creating it on first use. Caller
// holds gatesMu for writing. A creation past the high-water mark runs the
// rate-limited inline sweep so the index stays bounded without the eviction
// loop.
func (r *Directory) ensureGateLocked(key string, now time.Time) *State {
	r.gatesInitLocked()
	if g, ok := r.gates[key]; ok {
		return g
	}
	if len(r.gates) > gateSweepHighWater && now.Sub(r.gateSweepAt) > gateSweepMinInterval {
		r.sweepGatesLocked(now)
	}
	g := newGateState(key)
	g.touched = now // creation counts as activity: see gateState.touched
	r.gates[key] = g
	return g
}

// gateForKey returns the gate filed under an explicit fault key / stable
// identity (RecordProviderServeOutcome is keyed by the caller's stable id),
// creating it on first use. One gatesMu.RLock in the common case.
func (r *Directory) gateForKey(key string) Reference {
	r.gatesMu.RLock()
	g := r.gates[key]
	r.gatesMu.RUnlock()
	if g == nil {
		r.gatesMu.Lock()
		g = r.ensureGateLocked(key, r.now())
		r.gatesMu.Unlock()
	}
	return Reference{g: g.resolve(), key: key, insert: true}
}

// lookupGateForKey is gateForKey without the insert: nil when the identity has
// no state.
func (r *Directory) lookupGateForKey(key string) *State {
	r.gatesMu.RLock()
	g := r.gates[key]
	r.gatesMu.RUnlock()
	return g.resolve()
}

// gateForSession resolves a live session id to its identity's gate, creating
// the (session-keyed) gate when the identity has none. Precedence mirrors the
// old faultKeyLocked: the bound identity of a live session → the identity
// cached at Disconnect for the trailing ErrorCh flush → the session id itself.
// Recorders call this; it never touches r.mu.
func (r *Directory) gateForSession(sessionID string) Reference {
	return r.sessionGateRef(sessionID, true)
}

// lookupSessionGateRef is gateForSession without the insert: ref.g is nil when
// the session's identity has no state. The recorders that only CLEAR state
// (and so have nothing to do for an identity without a gate) resolve through
// this, so a straggling clear for a dead session never files a gate under
// its id — including when lockGate has to re-resolve.
func (r *Directory) lookupSessionGateRef(sessionID string) Reference {
	return r.sessionGateRef(sessionID, false)
}

// lookupGateForSession is the plain-pointer form of lookupSessionGateRef for
// readers (the scan's fallback for a bare provider, the *Active probes,
// tests): nil when the session's identity has no state.
func (r *Directory) lookupGateForSession(sessionID string) *State {
	return r.sessionGateRef(sessionID, false).g
}

func (r *Directory) sessionGateRef(sessionID string, insert bool) Reference {
	r.gatesMu.RLock()
	ref, _ := r.sessionGateRefLocked(sessionID, insert)
	r.gatesMu.RUnlock()
	if ref.g == nil && insert {
		r.gatesMu.Lock()
		// The session or cached identity may have changed since the miss.
		// Resolve again before inserting so an enrichment cannot recreate
		// state under the disconnected session's obsolete key.
		var key string
		ref, key = r.sessionGateRefLocked(sessionID, insert)
		if ref.g == nil {
			ref.g = r.ensureGateLocked(key, r.now())
		}
		r.gatesMu.Unlock()
	}
	ref.g = ref.g.resolve()
	return ref
}

// sessionGateRefLocked captures the cached binding in the same index read as
// the gate. Caller holds gatesMu (either mode).
func (r *Directory) sessionGateRefLocked(sessionID string, insert bool) (Reference, string) {
	g, key, via := r.resolveSessionGateLocked(sessionID)
	ref := Reference{g: g, p: via, session: sessionID, insert: insert}
	if via == nil {
		if cached, ok := r.disconnectedStableIDs[sessionID]; ok && cached.id == key {
			ref.disconnectedBinding = cached.binding
		}
	}
	return ref, key
}

// resolveSessionGateLocked returns the gate a session resolves to (nil when
// its key has no gate yet), that key, and — when the gate came from a live
// session's cached pointer — that session's Provider, so the caller can later
// detect a rebind (gateRef.p). Caller holds gatesMu (either mode).
func (r *Directory) resolveSessionGateLocked(sessionID string) (g *State, key string, via *Session) {
	if p := r.sessions[sessionID]; p != nil {
		if g := p.gate.Load(); g != nil {
			return g, g.key, p
		}
		return r.gates[sessionID], sessionID, nil
	}
	if c, ok := r.disconnectedStableIDs[sessionID]; ok && c.id != "" && r.now().Sub(c.at) < disconnectedStableIDTTL {
		return r.gates[c.id], c.id, nil
	}
	return r.gates[sessionID], sessionID, nil
}

// faultKeyForSession resolves a session provider id to the key its fault state
// lives under: the bound stable identity (serial/SE-key/account), the identity
// cached at Disconnect for the trailing ErrorCh flush, or — when no identity
// was ever available — the session id itself. Takes gatesMu for reading.
func (r *Directory) faultKeyForSession(sessionID string) string {
	r.gatesMu.RLock()
	defer r.gatesMu.RUnlock()
	_, key, _ := r.resolveSessionGateLocked(sessionID)
	return key
}

// attachSessionGate files a freshly registered session under its own id and
// caches the gate on the Provider. Called by Register (under r.mu; the order
// r.mu → gatesMu holds).
func (r *Directory) attachSessionGate(p *Session) {
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
func (r *Directory) detachSessionGate(p *Session, stableID string) {
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
