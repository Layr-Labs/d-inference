package faultstate

import (
	"time"
)

// gatesInit lazily creates the gate index so bare &Registry{} test
// constructions work without New(). Caller holds gatesMu for writing.
func (r *Manager[C]) gatesInitLocked() {
	if r.gates == nil {
		r.gates = make(map[string]*gateState)
	}
	if r.sessions == nil {
		r.sessions = make(map[string]*Session[C])
	}
	if r.disconnectedStableIDs == nil {
		r.disconnectedStableIDs = make(map[string]disconnectedStableID)
	}
}

// ensureGateLocked returns the gate for key, creating it on first use. Caller
// holds gatesMu for writing. A creation past the high-water mark runs the
// rate-limited inline sweep so the index stays bounded without the eviction
// loop.
func (r *Manager[C]) ensureGateLocked(key string, now time.Time) *gateState {
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
func (r *Manager[C]) gateForKey(key string) gateRef[C] {
	r.gatesMu.RLock()
	g := r.gates[key]
	r.gatesMu.RUnlock()
	if g == nil {
		r.gatesMu.Lock()
		g = r.ensureGateLocked(key, r.now())
		r.gatesMu.Unlock()
	}
	return gateRef[C]{g: g.resolve(), key: key, insert: true}
}

// lookupGateForKey is gateForKey without the insert: nil when the identity has
// no state.
func (r *Manager[C]) lookupGateForKey(key string) *gateState {
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
func (r *Manager[C]) gateForSession(sessionID string) gateRef[C] {
	return r.sessionGateRef(sessionID, true)
}

// lookupSessionGateRef is gateForSession without the insert: ref.g is nil when
// the session's identity has no state. The recorders that only CLEAR state
// (and so have nothing to do for an identity without a gate) resolve through
// this, so a straggling clear for a dead session never files a gate under
// its id — including when lockGate has to re-resolve.
func (r *Manager[C]) lookupSessionGateRef(sessionID string) gateRef[C] {
	return r.sessionGateRef(sessionID, false)
}

// lookupGateForSession is the plain-pointer form of lookupSessionGateRef for
// readers (the scan's fallback for a bare provider, the *Active probes,
// tests): nil when the session's identity has no state.
func (r *Manager[C]) lookupGateForSession(sessionID string) *gateState {
	return r.sessionGateRef(sessionID, false).g
}

func (r *Manager[C]) sessionGateRef(sessionID string, insert bool) gateRef[C] {
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
func (r *Manager[C]) sessionGateRefLocked(sessionID string, insert bool) (gateRef[C], string) {
	g, key, via := r.resolveSessionGateLocked(sessionID)
	ref := gateRef[C]{g: g, p: via, session: sessionID, insert: insert}
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
func (r *Manager[C]) resolveSessionGateLocked(sessionID string) (g *gateState, key string, via *Session[C]) {
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
func (r *Manager[C]) FaultKeyForSession(sessionID string) string {
	r.gatesMu.RLock()
	defer r.gatesMu.RUnlock()
	_, key, _ := r.resolveSessionGateLocked(sessionID)
	return key
}

// sessionProvider returns the live Provider for a session id without touching
// r.mu (the recorders that need a budget snapshot read p.BackendCapacity
// under p.mu). nil when the session is gone.
func (r *Manager[C]) Connection(sessionID string) C {
	r.gatesMu.RLock()
	defer r.gatesMu.RUnlock()
	if p := r.sessions[sessionID]; p != nil {
		return p.connection
	}
	var zero C
	return zero
}

// gateOf returns the gate the scan should consult for p: the pointer cached on
// the connected Provider (no lock), falling back to a session lookup for a
// Provider that was never registered (bare test objects). nil-safe result:
// every gate read treats a nil gate as "no state".
func (r *Manager[C]) gateOf(p *Session[C], sessionID string) *gateState {
	if p == nil {
		return nil
	}
	if g := p.gate.Load(); g != nil {
		return g.resolve()
	}
	return r.lookupGateForSession(sessionID)
}

// gateCount reports the size of the gate index (tests / observability).
func (r *Manager[C]) Count() int {
	r.gatesMu.RLock()
	defer r.gatesMu.RUnlock()
	return len(r.gates)
}
