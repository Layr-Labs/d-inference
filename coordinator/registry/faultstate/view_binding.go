package faultstate

// gateView is the routing read path's handle on a session's gate for one
// batch of reads: the gate gateOf loaded plus the Provider it was loaded
// from, so the reads can be confirmed against the pointer afterwards. A value
// type — the scan allocates nothing.
//
// Here p is the opaque Session; p.mu below denotes its caller-owned Provider
// lock. A rebind runs under that lock (bindStableFaultKey's callers hold
// it), so a read made under p.mu sees one p.gate for its whole section. Not
// every dispatch-deciding read is made there — the candidate's capacity-rate
// penalty (buildCandidateInto) is computed after the scan has released p.mu —
// and the gate chain's p.mu is its caller's contract, not this file's, so the
// reads are confirmed independently of that lock. Without it, a gate is read
// lock-free (or under gate.mu for the per-model maps) holding nothing a rebind
// respects, and a rebind that lands between the load and the reads can leave
// the loaded gate saying nothing about the session:
// migrateGateLocked moves the state to the session's new gate and, when the
// source is SHARED with another live session, resets the source and
// republishes it — zeros. A scan trusting that view would dispatch the
// session past a breaker or cooldown that moved with it. So every batch of
// reads is confirmed (moved): if p.gate still resolves to the gate that was
// read, the verdict stands; otherwise the view is rebased on the new gate and
// the reads run again. Sound without a lock because the migration repoints
// p.gate BEFORE it resets and republishes the source (all under the source's
// mu) and Go's atomics are sequentially consistent: a reader whose confirming
// load still returns the source made its atomic reads before the zeroing
// stores, and a reader that took the source's mu after the migration finds
// the pointer moved. Both verdicts are confirmed — a reset source can already
// carry the sibling session's fresh faults, which are not this session's.
//
// Which reads confirm: everything that feeds a dispatch decision — the
// routing gate (gateStateReasonLocked: the scan, the commit's admit re-check
// and the preflight), the snapshot's budget clamp (budgetClampedFor) and the
// candidate's capacity-rate penalty (capacityRatePenaltyFor). Rejected-provider
// classification (classifyRejectedProvider) also confirms its view because it
// controls the fail-open rescan and capacity/no-provider response. Gate tallies,
// fleet_sample rows and warm-pool planning read gateOf unconfirmed: a stale
// sample there miscounts once and dispatches nothing.
//
// No retired check: the sweep drops only gates with no live session, and
// every read site holds r.mu (Disconnect removes the session under
// r.mu.Lock) or checks r.providers[p.id] == p under it, so a live session's
// gate is never retired underneath a read.
type View[C comparable] struct {
	owner   *Manager[C]
	p       *Session[C]
	g       *gateState
	rereads int
}

// gateViewOf loads the gate the routing reads for p consult (gateOf) into a
// view to confirm them against. nil-safe: a nil or never-registered Provider
// has no cached gate, and nothing can rebind it.
func (r *Manager[C]) ViewOf(p *Session[C], sessionID string) View[C] {
	return View[C]{p: p, g: r.gateOf(p, sessionID), owner: r}
}

// moved reports whether the session rebound since the view was loaded — its
// cached gate no longer resolves to v.g — and, when it did, rebases the view
// on the session's current gate so the caller re-reads. Bounded by
// gateRelockMaxRetries like lockGate's re-resolve; at the bound the last
// view's verdict stands (today's behaviour, no worse).
func (v *View[C]) Moved() bool {
	if v.p == nil || v.rereads >= gateRelockMaxRetries {
		return false
	}
	cur := v.p.gate.Load()
	if cur == nil {
		return false // never registered: nothing rebinds a bare Provider
	}
	if cur = cur.resolve(); cur == v.g {
		return false
	}
	v.g = cur
	v.rereads++
	return true
}
