package faultstate

import (
	"time"
)

// gateWaitReportThreshold is the gate.mu acquisition wait above which the
// wait is reported to the gate-wait observer (registry.gate.wait_ms). Below it
// the lock is doing what it should; above it something is holding a gate too
// long or the convoy is re-forming on a new lock.
const gateWaitReportThreshold = time.Millisecond

// lockResolved locks the gate, following a migration that landed between the
// caller's resolve and the lock. The caller unlocks the RETURNED gate.
func (g *gateState) lockResolved() *gateState {
	for {
		g.mu.Lock()
		next := g.forwardTo.Load()
		if next == nil {
			return g
		}
		g.mu.Unlock()
		g = next
	}
}

// gateRef is a recorder's resolution of a gate: the gate plus how it was
// reached, so that lockGate can prove — under gate.mu — that the gate is
// still the one the outcome belongs to, and re-resolve when it is not. A
// value type: the recorder path allocates nothing.
type gateRef[C comparable] struct {
	g *gateState
	// p is the live session whose cached p.gate produced g; nil when g was
	// reached through the disconnect cache, the bare session id or an
	// explicit fault key. After the lock,
	// p.gate.Load() != g means the session rebound to another gate in
	// between and the outcome belongs there.
	p *Session[C]
	// A disconnected identity can still be enriched by a live sibling. Its
	// cache-owned redirect validates that move without retaining Provider or
	// acquiring gatesMu while gate.mu is held.
	disconnectedBinding *disconnectedGateBinding
	// Exactly one of session / key names what to re-resolve.
	session string
	key     string
	// insert says whether re-resolution may create the gate (gateForSession /
	// gateForKey) or must find an existing one (lookupSessionGateRef: the
	// "clear" recorders, which have nothing to clear on an identity without a
	// gate and must not file one under a dead session id).
	insert bool
}

// currentLocked reports whether g — locked by the caller — is still the gate
// ref's outcome belongs to: not retired by the sweep, and, when the ref was
// reached through a live session's cached pointer, still that session's gate.
func (ref gateRef[C]) currentLocked(g *gateState) bool {
	if g.retired {
		return false
	}
	return ref.bindingCurrent(g)
}

// bindingCurrent is safe for the lock-free pair-flag probe as well as the
// locked validation. All identity redirects publish before resetting src.
func (ref gateRef[C]) bindingCurrent(g *gateState) bool {
	if ref.p != nil {
		// A ref captured while live must switch to the disconnect cache on
		// drop; a later sibling enrichment redirects that cache, not this
		// detached Provider's cached gate pointer.
		return ref.p.gateDisconnectedAtNS.Load() == 0 && ref.p.gate.Load() == g
	}
	if ref.disconnectedBinding != nil {
		return g != nil && ref.disconnectedBinding.load() == g.key
	}
	return true
}

// gateRelockMaxRetries bounds how many times lockGate re-resolves a gate that
// went stale between the index lookup and the lock, and how many times a
// routing read re-reads a gate the session moved away from (gateView.moved).
// One retry is the expected maximum (a rebind or a sweep landed in the
// window). A recorder that exhausts the optimistic retries stabilizes the
// index while resolving and acquiring the gate; it never mutates a stale
// gate merely to bound the number of retries.
const gateRelockMaxRetries = 4

// lockGate acquires gate.mu for a recorder at the named site. It follows any
// migration forward (see lockResolved) and then validates, under the lock,
// that the gate is still current for the ref (currentLocked); a stale gate is
// released and the ref re-resolved through the index — gatesMu is never
// taken while a gate.mu is held, so the lock order stands — and locked again.
// The uncontended path is one TryLock — no clock reads; only a contended
// acquisition is timed, and only a wait above gateWaitReportThreshold is
// reported. The caller uses hold.g (the gate actually locked) and calls
// hold.unlock. A vanished no-insert identity returns a nil gate; callers must
// treat that hold as a no-op.
func (r *Manager[C]) lockGate(ref gateRef[C], site string) gateHold[C] {
	return r.lockGateWithRetries(ref, site, 0)
}

// lockGateWithRetries carries the optimistic retry count explicitly so the
// exhaustion path can be exercised without scheduling several racing rebinds.
func (r *Manager[C]) lockGateWithRetries(ref gateRef[C], site string, retries int) gateHold[C] {
	var wait time.Duration
	g := ref.g
	for {
		if retries >= gateRelockMaxRetries {
			return r.lockGateWithIndex(ref, site, wait)
		}
		if g == nil {
			return gateHold[C]{r: r, site: site, wait: wait}
		}
		if !g.mu.TryLock() {
			start := time.Now()
			g.mu.Lock()
			wait += time.Since(start)
		}
		if next := g.forwardTo.Load(); next != nil {
			g.mu.Unlock()
			g = next
			retries++
			continue
		}
		if ref.currentLocked(g) {
			return gateHold[C]{g: g, r: r, site: site, wait: wait}
		}
		// Never retain g after a failed validation: it may still belong to
		// another live session even if this session's next lookup is empty.
		g.mu.Unlock()
		retries++
		if retries >= gateRelockMaxRetries {
			continue
		}
		ref = r.reresolveGate(ref)
		g = ref.g
	}
}

// lockGateWithIndex is the rare retry-exhaustion path. Holding gatesMu until
// the current gate is locked prevents a rebind or sweep from invalidating the
// resolution. The index lock is released before returning the gate, preserving
// gatesMu -> gate.mu without taking r.mu or p.mu. The write lock permits an
// inserting recorder to recreate an idle gate retired by a concurrent sweep.
func (r *Manager[C]) lockGateWithIndex(ref gateRef[C], site string, wait time.Duration) gateHold[C] {
	start := time.Now()
	r.gatesMu.Lock()
	defer r.gatesMu.Unlock()
	key := ref.key
	var g *gateState
	if key != "" {
		g = r.gates[key]
	} else {
		g, key, _ = r.resolveSessionGateLocked(ref.session)
	}
	if g == nil && ref.insert {
		g = r.ensureGateLocked(key, r.now())
	}
	g = g.resolve()
	if g == nil {
		return gateHold[C]{r: r, site: site, wait: wait + time.Since(start)}
	}
	g.mu.Lock()
	return gateHold[C]{g: g, r: r, site: site, wait: wait + time.Since(start)}
}

// reresolveGate resolves ref again through the index (takes gatesMu; the
// caller holds no gate.mu).
func (r *Manager[C]) reresolveGate(ref gateRef[C]) gateRef[C] {
	if ref.key != "" {
		return r.gateForKey(ref.key)
	}
	return r.sessionGateRef(ref.session, ref.insert)
}

// refHasPairState is the lock-free "does this identity hold any of the
// flagged per-model state" fast path for a ref about to be locked, made safe
// against a rebind: an emptied source gate's flag says "nothing" precisely
// because the state moved to the session's new gate, so a cleared flag counts
// only while p.gate still points at ref.g; otherwise the ref is re-resolved
// and the flag read again. Sound without a lock because the migration
// repoints p.gate BEFORE it republishes the emptied source (migrateGateLocked)
// — a reader that sees the cleared flag then sees the moved pointer. A set
// flag needs no confirmation: the caller proceeds to lockGate, which
// validates under the lock. Returns the ref to lock. A retired gate needs no
// handling here: it was idle, so "nothing" is true for the identity.
func (r *Manager[C]) refHasPairState(ref gateRef[C], flag uint32) (gateRef[C], bool) {
	for retries := 0; ; retries++ {
		has := ref.g.hasPairState(flag)
		if has || ref.bindingCurrent(ref.g) {
			return ref, has
		}
		if retries >= gateRelockMaxRetries {
			// A stale false flag cannot prove there is nothing to clear or
			// claim. Force the caller through lockGate's validated acquisition.
			return ref, true
		}
		ref = r.reresolveGate(ref)
	}
}

// gateHold is an acquired gate.mu. unlock releases the gate and only then
// reports a long acquisition wait to the observer, so the DogStatsD emit never
// runs inside the critical section.
type gateHold[C comparable] struct {
	g    *gateState
	r    *Manager[C]
	site string
	wait time.Duration
}

func (h gateHold[C]) unlock() {
	if h.g != nil {
		h.g.mu.Unlock()
	}
	if h.r != nil && h.wait > gateWaitReportThreshold {
		if obs := h.r.gateWaitObserver.Load(); obs != nil {
			(*obs)(h.site, h.wait)
		}
	}
}

// SetGateWaitObserver registers an optional observer for gate.mu acquisition
// waits above gateWaitReportThreshold on the recorder sites. The api layer
// turns it into the registry.gate.wait_ms histogram tagged by site, so the
// per-identity locks that replaced the global write lock are observable. Set
// once at startup; nil clears it. Thread-safe.
func (r *Manager[C]) SetGateWaitObserver(fn func(site string, wait time.Duration)) {
	if fn == nil {
		r.gateWaitObserver.Store(nil)
		return
	}
	r.gateWaitObserver.Store(&fn)
}

// HoldGateForTest acquires the gate.mu of the provider's current gate and
// returns the release function. Test-only (mirrors reservationAfterScan): it
// lets a test prove a recorder blocks on the identity's gate, not on r.mu, and
// that a long wait reaches the observer. Production code never calls it.
func (r *Manager[C]) HoldGateForTest(providerID string) (release func()) {
	hold := r.lockGate(r.gateForSession(providerID), "test")
	return hold.g.mu.Unlock
}
