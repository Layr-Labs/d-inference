package registry

import "time"

// gate_sweep.go — bounding the gate index: the per-gate prune of dead
// per-model entries and the periodic sweep that retires idle gates no live
// session references. Design, lock order and file map: gate_state.go.

// gateIdleGrace is how long a gate with no live session must stay idle (every
// tracker expired or empty and nothing recorded) before the sweep drops it. A
// disconnected identity keeps its half-open trip memory for at least this long.
const gateIdleGrace = 10 * time.Minute

// gateSweepHighWater is the gate count above which an insert triggers an
// inline sweep (rate-limited by gateSweepMinInterval) so the index stays
// bounded even when the eviction loop is not running. The loop sweeps every
// timeout/3 (30 s at the default), so with a 60 s minimum interval the inline
// path — a walk of every gate under gatesMu.Lock, on a recorder's insert —
// never fires in a process that runs the loop.
const (
	gateSweepHighWater   = 4096
	gateSweepMinInterval = 60 * time.Second
)

// pruneLocked drops per-model entries that can no longer influence routing
// and reports whether the whole gate is idle: nothing open, no windowed
// history, no live per-model state. It mirrors what the old size-triggered
// map sweeps removed — with one deliberate difference: half-open memory
// (breaker/cooldown trip counts, an expired cooldown entry awaiting its
// probe, a fault ring's consecutive-fault counter) is NEVER pruned from a gate
// that still has a live session, because the old sweeps only ran past 1024
// entries and the half-open re-arm semantics depend on that memory. Such
// memory goes only when the whole gate is dropped. Caller holds g.mu.
func (g *gateState) pruneLocked(r *Registry, now time.Time) (idle bool) {
	idle = !g.versionHistoryActive(now)
	for model, expiry := range g.dispatchLoadCooldowns {
		if !now.Before(expiry) {
			delete(g.dispatchLoadCooldowns, model)
		}
	}
	for k, expiry := range g.inferenceErrorCooldowns {
		if !now.Before(expiry) {
			delete(g.inferenceErrorCooldowns, k)
		}
	}
	for k, strikes := range g.inferenceErrorStrikes {
		if len(strikes) == 0 || !strikes[len(strikes)-1].Add(inferenceErrorWindow).After(now) {
			delete(g.inferenceErrorStrikes, k)
			delete(g.inferenceErrorFlushStrikes, k)
		}
	}
	window := r.capacityCooldownCfg.Window
	for model, strikes := range g.capacityRejectStrikes {
		if len(strikes) == 0 || !strikes[len(strikes)-1].Add(window).After(now) {
			delete(g.capacityRejectStrikes, model)
		}
	}
	for model, e := range g.budgetClamps {
		if !now.Before(e.clampedAt.Add(r.budgetClampCfg.TTL)) {
			delete(g.budgetClamps, model)
		}
	}
	for model, outcomes := range g.capacityRateRejects {
		if len(outcomes) == 0 || now.Sub(outcomes[len(outcomes)-1]) >= capacityRateWindow {
			delete(g.capacityRateRejects, model)
		}
	}
	for model, outcomes := range g.capacityRateAccepts {
		if len(outcomes) == 0 || now.Sub(outcomes[len(outcomes)-1]) >= capacityRateWindow {
			delete(g.capacityRateAccepts, model)
		}
	}

	if len(g.dispatchLoadCooldowns)+len(g.inferenceErrorCooldowns)+len(g.inferenceErrorStrikes)+
		len(g.capacityRejectStrikes)+len(g.budgetClamps)+len(g.capacityRateRejects)+len(g.capacityRateAccepts) > 0 {
		idle = false
	}
	for _, e := range g.capacityCooldowns {
		// An expired entry with a fresh probe claim is still gating (see
		// capacityCooldownActiveLocked); one whose claim is stale or absent is
		// half-open memory only.
		if now.Before(e.expiry) || (!e.probeAt.IsZero() && now.Before(e.probeAt.Add(capacityProbeOutcomeWindow))) {
			idle = false
		}
	}
	if now.Before(g.breakerUntil) || now.Before(g.ejectionUntil) {
		idle = false
	}
	if g.outcomes != nil {
		if total, _ := g.outcomes.windowStats(now, providerBreakerWindow); total > 0 {
			idle = false
		}
	}
	if g.ejection != nil {
		if total, _ := g.ejection.windowStats(now, healthEjectionWindow); total > 0 {
			idle = false
		}
	}
	if g.ejectionCapacityStreak.n > 0 && now.Sub(g.ejectionCapacityStreak.last) <= healthEjectionWindow {
		idle = false
	}
	return idle
}

// sweepGates bounds the gate index: it prunes dead per-model entries from
// every gate and drops gates that no live session references once they have
// been idle for gateIdleGrace. Called from the eviction loop (every
// timeout/3) and inline from an insert past the high-water mark. Each gate is
// locked for microseconds; gatesMu is held for the walk, which is why this
// runs at most every few seconds and never on the request path.
func (r *Registry) sweepGates(now time.Time) {
	r.gatesMu.Lock()
	defer r.gatesMu.Unlock()
	r.gatesInitLocked()
	r.sweepGatesLocked(now)
}

func (r *Registry) sweepGatesLocked(now time.Time) {
	r.gateSweepAt = now
	for key, g := range r.gates {
		g.mu.Lock()
		idle := g.pruneLocked(r, now)
		g.publishLocked()
		drop := idle && g.live <= 0 && now.Sub(g.touched) > gateIdleGrace
		if drop {
			// Retire under g.mu BEFORE the index delete: a recorder that
			// resolved this gate before the walk and locks it afterwards
			// sees retired and re-resolves (lockGate) instead of writing a
			// trailing fault into a gate no lookup will ever find again.
			g.retired = true
		}
		g.mu.Unlock()
		if drop {
			delete(r.gates, key)
		}
	}
	cutoff := now.Add(-disconnectedStableIDTTL)
	for k, v := range r.disconnectedStableIDs {
		if v.at.Before(cutoff) {
			delete(r.disconnectedStableIDs, k)
		}
	}
}
