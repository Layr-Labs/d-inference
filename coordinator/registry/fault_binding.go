package registry

import (
	"time"
)

// faultKeyForSession resolves a session provider id to the key its fault state
// lives under: the bound stable identity (serial/SE-key/account), the identity
// cached at Disconnect for the trailing ErrorCh flush, or — when no identity
// was ever available — the session id itself. Takes gatesMu for reading.
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

// attachSessionGate files a freshly registered session under its own id and
// caches the gate on the Provider. Called by Register (under r.mu; the order
// r.mu → gatesMu holds).
func (r *Registry) attachSessionGate(p *Provider) {
	r.faults.Attach(&p.faultSession, p, p.ID)
}

// detachSessionGate removes a disconnecting session from the index. stableID
// is the identity derived at disconnect: when present it is cached so the
// trailing pending-request flush still resolves the session (its state lives
// on under the identity's gate — FAULT STATE IS NOT CLEARED ON DISCONNECT);
// when absent the session-keyed gate is the only thing that ever referenced
// this identity, so its residue is dropped for hygiene, exactly as the old
// implementation dropped the session-keyed map entries. Called by Disconnect
// (under r.mu and p.mu; the order r.mu → p.mu → gatesMu holds).
func (r *Registry) detachSessionGate(p *Provider, stableID string) {
	r.faults.Detach(&p.faultSession, stableID)
}

// bindStableFaultKey binds a live session to its stable identity so every
// fault tracker keys by identity and survives reconnects. Called by
// SetAttestationResult on every (re-)attestation — i.e. BEFORE the session is
// routable for public traffic — which is what re-attaches a reconnecting
// machine's accumulated fault state to its fresh session id. An empty stableID
// (attestation cleared / never valid) unbinds, falling back to session keying;
// the identity's state stays on its own gate (an unbind never migrates).
//
// Only LIVE sessions bind: a re-attestation racing Disconnect must not
// re-insert an entry Disconnect already removed. Liveness is the sessions
// index under gatesMu, so this never takes r.mu.
//
// Caller holds p.mu (SetAttestationResult, RebindStableFaultKey; lock order
// r.mu → p.mu → gatesMu → gate.mu). The bind repoints p.faultSession, and the routing
// sections that read p.faultSession and ACT on the verdict do so under p.mu — the
// reservation commit from its admit re-check through the pending debit
// (commitProviderReservation, ReserveNextFromPlan), the scan's gate chain
// (gateStateReasonLocked), the alias resolver's routability read
// (providerCanRouteBuildLocked) — so with the bind under the same lock none
// of them can accept a clean gate and then act after the session has moved
// to an identity that is quarantined. The map-keyed implementation had this
// for free (the bind and the commit shared r.mu.Lock).
//
// Accumulated fault state migrates when the key changes: from the session id
// on the FIRST bind (strikes recorded pre-attestation live on the session
// gate), or from the previous identity on a rebind (e.g. sekey: → serial:
// after MDA enrichment). Without this, a machine near quarantine sheds its
// history at the exact moment its identity improves. No-op on the common
// re-attestation with an unchanged identity.
func (r *Registry) bindStableFaultKey(p *Provider, stableID string) {
	if p == nil {
		return
	}
	r.faults.Bind(&p.faultSession, stableID, p.Version)
}

// sweepGates bounds the gate index: it prunes dead per-model entries from
// every gate and drops gates that no live session references once they have
// been idle for gateIdleGrace. Called from the eviction loop (every
// timeout/3) and inline from an insert past the high-water mark. Each gate is
// locked for microseconds; gatesMu is held for the walk, which is why this
// runs at most every few seconds and never on the request path.
func (r *Registry) sweepGates(now time.Time) {
	r.faults.Sweep(now)
}

// SetGateWaitObserver registers an optional observer for gate.mu acquisition
// waits above gateWaitReportThreshold on the recorder sites. The api layer
// turns it into the registry.gate.wait_ms histogram tagged by site, so the
// per-identity locks that replaced the global write lock are observable. Set
// once at startup; nil clears it. Thread-safe.
func (r *Registry) SetGateWaitObserver(fn func(site string, wait time.Duration)) {
	r.faults.SetGateWaitObserver(fn)
}

// HoldGateForTest acquires the gate.mu of the provider's current gate and
// returns the release function. Test-only (mirrors reservationAfterScan): it
// lets a test prove a recorder blocks on the identity's gate, not on r.mu, and
// that a long wait reaches the observer. Production code never calls it.
func (r *Registry) HoldGateForTest(providerID string) (release func()) {
	return r.faults.HoldGateForTest(providerID)
}

// SetVersion observes the bound identity while p.mu excludes a concurrent
// rebind. The index lock stabilizes lookup until the gate has been acquired.
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
