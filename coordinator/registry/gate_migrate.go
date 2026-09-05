package registry

import "time"

// gate_migrate.go — identity binds and the migration of accumulated fault
// state between gates: the forward a migrated-away gate leaves behind
// (resolve), the merge and reset policy, bindStableFaultKey and
// migrateGateLocked. Design, lock order and file map: gate_state.go.
//
// Rebind semantics. Fault state is keyed by IDENTITY, and a rebind MOVES the
// identity's accumulated state to the refined identity (session id → sekey:
// on the first bind, sekey: → serial: on MDA enrichment); the source identity
// is left with nothing — exactly what the map-keyed implementation did
// (migrateFaultStateLocked deleted the old key's entries). When the source
// gate is SHARED with another live session (the same machine connected twice:
// one SE key, two sessions), that session's identity starts from nothing too:
// the state was the machine's and now lives under the machine's better key,
// where the sibling lands at its own enrichment. It is deliberately not
// copied — mergeLocked does not deduplicate histories, so a copy would
// double-count every fault (strike lists, health rings, consecutive-fault
// streaks) the moment the sibling enriches to the same serial. The shared
// source's reset is published (its atomics zeroed) so the sibling's readers
// see the move at once. A bind runs under the rebinding session's p.mu, so
// the routing sections that hold p.mu (the scan's gate chain, the reservation
// commit through its debit, the alias resolver) never observe the move
// mid-section; the routing readers also confirm their view against p.gate
// (gateView) so a read made without p.mu cannot mistake the emptied source
// for the session's state, and the recorders re-validate under gate.mu
// (lockGate) for the same reason.

// resolve follows forwardTo to the gate that currently holds this identity's
// state. Lock-free; one atomic load in the common (not migrated) case.
// nil-safe.
func (g *gateState) resolve() *gateState {
	for g != nil {
		next := g.forwardTo.Load()
		if next == nil {
			return g
		}
		g = next
	}
	return nil
}

// mergeLocked folds src's state into g for an identity rebind whose new key
// ALREADY has history (e.g. this session's sekey:-keyed faults migrating onto
// a serial: gate populated by a previous connection). Merge policy: expiries
// and streak recency take the max, trip counts take the max, timestamp
// histories merge chronologically, health rings merge in timestamp order
// bounded by the ring size (providerHealthWindow.merge) so an in-progress
// consecutive-fault streak survives the rebind, and a clamp entry with the
// later clamp time wins whole. Caller holds BOTH g.mu and src.mu (only the
// identity bind, under gatesMu.Lock, ever does).
func (g *gateState) mergeLocked(src *gateState) {
	if g.identityVersion == "" {
		g.identityVersion = src.identityVersion
	}
	if src.versionResetAt.After(g.versionResetAt) {
		g.versionResetAt = src.versionResetAt
	}
	if len(src.inferenceErrorFlushStrikes) > 0 && g.inferenceErrorFlushStrikes == nil {
		g.inferenceErrorFlushStrikes = make(map[modelShapeKey][]time.Time)
	}
	for key, stamps := range src.inferenceErrorFlushStrikes {
		g.inferenceErrorFlushStrikes[key] = mergeChronologicalTimestamps(g.inferenceErrorFlushStrikes[key], stamps)
	}
	for model, expiry := range src.dispatchLoadCooldowns {
		if cur, ok := g.dispatchLoadCooldowns[model]; !ok || expiry.After(cur) {
			g.dispatchLoadCooldowns[model] = expiry
		}
	}
	for k, strikes := range src.inferenceErrorStrikes {
		g.inferenceErrorStrikes[k] = mergeChronologicalTimestamps(g.inferenceErrorStrikes[k], strikes)
	}
	for k, expiry := range src.inferenceErrorCooldowns {
		if cur, ok := g.inferenceErrorCooldowns[k]; !ok || expiry.After(cur) {
			g.inferenceErrorCooldowns[k] = expiry
		}
	}

	if src.outcomes != nil {
		if g.outcomes != nil {
			g.outcomes.merge(src.outcomes)
		} else {
			g.outcomes = src.outcomes
		}
	}
	if src.breakerUntil.After(g.breakerUntil) {
		g.breakerUntil = src.breakerUntil
	}
	if src.breakerTrips > g.breakerTrips {
		g.breakerTrips = src.breakerTrips
	}

	for model, strikes := range src.capacityRejectStrikes {
		g.capacityRejectStrikes[model] = mergeChronologicalTimestamps(g.capacityRejectStrikes[model], strikes)
	}
	for model, entry := range src.capacityCooldowns {
		if cur, ok := g.capacityCooldowns[model]; !ok || entry.expiry.After(cur.expiry) {
			g.capacityCooldowns[model] = entry
		}
	}
	for model, trips := range src.capacityCooldownTrips {
		if cur, ok := g.capacityCooldownTrips[model]; !ok || trips > cur {
			g.capacityCooldownTrips[model] = trips
		}
	}
	for model, entry := range src.budgetClamps {
		if cur, ok := g.budgetClamps[model]; !ok || entry.clampedAt.After(cur.clampedAt) {
			g.budgetClamps[model] = entry
		}
	}
	for model, outcomes := range src.capacityRateRejects {
		g.capacityRateRejects[model] = mergeChronologicalTimestamps(g.capacityRateRejects[model], outcomes)
	}
	for model, outcomes := range src.capacityRateAccepts {
		g.capacityRateAccepts[model] = mergeChronologicalTimestamps(g.capacityRateAccepts[model], outcomes)
	}

	if src.ejection != nil {
		if g.ejection != nil {
			g.ejection.merge(src.ejection)
		} else {
			g.ejection = src.ejection
		}
	}
	if src.ejectionUntil.After(g.ejectionUntil) {
		g.ejectionUntil = src.ejectionUntil
	}
	// The last-trip marker travels with the trip count it describes: the
	// destination's own marker wins when it has trips of its own.
	if g.ejectionTrips == 0 {
		g.ejectionLastTripCapacity = src.ejectionLastTripCapacity
	}
	if src.ejectionTrips > g.ejectionTrips {
		g.ejectionTrips = src.ejectionTrips
	}
	if src.ejectionCapacityStreak.n > g.ejectionCapacityStreak.n {
		g.ejectionCapacityStreak = src.ejectionCapacityStreak
	}
	if src.touched.After(g.touched) {
		g.touched = src.touched
	}
}

// resetLocked drops every tracker (the key, live count and forwardTo stay).
// After a migration the source key starts from nothing, as the old map-keyed
// implementation left it. Caller holds g.mu.
func (g *gateState) resetLocked() {
	g.identityVersion = ""
	g.versionResetAt = time.Time{}
	clear(g.inferenceErrorFlushStrikes)
	g.outcomes, g.breakerUntil, g.breakerTrips = nil, time.Time{}, 0
	g.ejection, g.ejectionUntil, g.ejectionTrips = nil, time.Time{}, 0
	g.ejectionCapacityStreak, g.ejectionLastTripCapacity = capacityStreak{}, false
	g.inferenceErrorStrikes = make(map[modelShapeKey][]time.Time)
	g.inferenceErrorCooldowns = make(map[modelShapeKey]time.Time)
	g.dispatchLoadCooldowns = make(map[string]time.Time)
	g.capacityRejectStrikes = make(map[string][]time.Time)
	g.capacityCooldowns = make(map[string]*capacityCooldownEntry)
	g.capacityCooldownTrips = make(map[string]int)
	g.budgetClamps = make(map[string]*budgetClampEntry)
	g.capacityRateRejects = make(map[string][]time.Time)
	g.capacityRateAccepts = make(map[string][]time.Time)
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
// r.mu → p.mu → gatesMu → gate.mu). The bind repoints p.gate, and the routing
// sections that read p.gate and ACT on the verdict do so under p.mu — the
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
	if p == nil || p.ID == "" {
		return
	}
	now := time.Now()
	r.gatesMu.Lock()
	defer r.gatesMu.Unlock()
	r.gatesInitLocked()
	if r.sessions[p.ID] != p {
		return
	}
	targetKey := stableID
	if targetKey == "" {
		targetKey = p.ID
	}
	cur := p.gate.Load()
	if cur != nil && cur.key == targetKey {
		if stableID != "" {
			cur.mu.Lock()
			cur.noteIdentityVersionLocked(r, p.Version)
			cur.updatedLocked(now)
			cur.mu.Unlock()
		}
		return
	}
	target := r.ensureGateLocked(targetKey, now)
	if cur != nil && stableID != "" {
		// Migrate, and repoint the session INSIDE the migration's locked
		// section: a lock-free reader that loads p.gate must find either cur's
		// intact pre-migration view or a target that already carries the
		// merged state, never an empty target; and a recorder that resolved
		// cur before this rebind must, once it holds cur.mu, either have
		// written before the merge (its outcome travels to target) or find
		// p.gate moved and re-resolve (lockGate) — never write into the
		// emptied cur. That matters most when cur is SHARED with another
		// session (cur.live > 1): it stays in the index for that session and
		// carries no forward, so the session's own pointer is the only thing
		// that can tell a stale recorder its outcome now belongs to target.
		// (An unbind never migrates: session keying resumes and the identity
		// keeps its state.) cur is orphaned when this was its last live
		// session.
		r.migrateGateLocked(p, cur, target, cur.live <= 1)
	} else {
		p.gate.Store(target)
	}
	if stableID != "" {
		target.mu.Lock()
		target.noteIdentityVersionLocked(r, p.Version)
		target.updatedLocked(now)
		target.mu.Unlock()
	}
	target.live++
	if cur != nil {
		cur.live--
	}
}

// migrateGateLocked re-keys accumulated fault state from src to dst (merge
// policy in mergeLocked) and repoints p (the session being bound) at dst
// while BOTH gates are locked, so no recorder can hold src.mu with p still
// pointing at src after the merge. src is emptied afterwards; when no live
// session still points at it (orphan) it is forwarded to dst and dropped from
// the index so stale pointers land on the live state. The only place two gate
// locks nest; caller holds gatesMu for writing, which serializes migrations.
func (r *Registry) migrateGateLocked(p *Provider, src, dst *gateState, orphan bool) {
	if src == dst {
		p.gate.Store(dst)
		return
	}
	src.mu.Lock()
	dst.mu.Lock()
	dst.mergeLocked(src)
	dst.publishLocked()
	p.gate.Store(dst)
	// Redirect cached disconnected sessions while src.mu is still held, so
	// a recorder that resolved src before this migration cannot write into
	// the reset source when it remains live for an unenriched sibling.
	r.retargetDisconnectedGateBindingsLocked(src.key, dst.key)
	if orphan {
		// Forward BEFORE resetting, and never republish the orphan: a
		// lock-free reader that loaded src sees either its intact pre-merge
		// atomics (stale but conservative — expiries merged by max into dst)
		// or the forward, never zeros. Locked reads follow the forward.
		src.forwardTo.Store(dst)
		if r.gates[src.key] == src {
			delete(r.gates, src.key)
		}
		src.resetLocked()
	} else {
		// Still bound to other sessions: it starts from nothing, visibly
		// (rebind semantics in the file header). Published AFTER the repoint
		// above, which is what lets a routing reader confirm a view of the
		// zeros against p.gate (gateView) and a lock-free flag check trust a
		// cleared flag (refHasPairState).
		src.resetLocked()
		src.publishLocked()
	}
	dst.mu.Unlock()
	src.mu.Unlock()
}
