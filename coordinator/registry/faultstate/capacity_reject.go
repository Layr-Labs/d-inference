package faultstate

// recordCapacityReject is the shared implementation. deratePair gates the
// gray-box capacity-503 rate window (true only for genuine capacity rejects);
// armClamp gates the budget clamp (false only for request-deterministic
// rejects, which indict the request rather than the provider). The cooldown
// strike is fed on all paths.
//
// The pair's budget snapshot (does the provider currently report a token
// budget for the model?) is read under p.mu BEFORE the gate is taken — the
// lock order is p.mu → gate.mu, never the reverse. Only gate.mu is then held;
// never r.mu.
func (r *Manager[C]) RecordCapacityReject(providerID, modelID string, deratePair, armClamp, budgetReported bool) (tripped bool) {
	if providerID == "" || modelID == "" {
		return false
	}
	hold := r.lockGate(r.gateForSession(providerID), "capacity_reject")
	defer hold.unlock()
	g := hold.g
	now := r.now()
	defer g.updatedLocked(now)

	// Gray-box trackers ride the SAME classified entry point but have their own
	// kill switches, independent of the cooldown threshold: the budget clamp
	// stops admission believing the pair's stale heartbeat budget immediately
	// (budget_clamp.go), and the rate window accumulates the reject side of the
	// capacity-503 rate (capacity_rate.go — accepts deliberately do NOT reset
	// it, unlike the strike streak below). The rate window is fed ONLY for a
	// derating reject: a cold-load lifecycle miss (deratePair=false) is warm-up,
	// not capacity dishonesty, and must not accumulate a rate the window can
	// never reset off. The clamp is armed only when the reject indicts the
	// PROVIDER (armClamp=false for request-deterministic rejects — an oversized
	// prompt says nothing about the pair's budget honesty).
	if armClamp {
		g.recordBudgetClampLocked(r.budgetClampCfg, modelID, budgetReported, now)
	}
	if deratePair {
		g.recordCapacityRateRejectLocked(r.capacityRateCfg, modelID, now)
	}

	cfg := r.capacityCooldownCfg
	if cfg.Threshold <= 0 {
		return false // disabled via EIGENINFERENCE_CAPACITY_COOLDOWN_THRESHOLD=0
	}

	// Slide the window: keep only strikes still inside it, then add this one.
	strikes := g.capacityRejectStrikes[modelID]
	kept := strikes[:0]
	for _, ts := range strikes {
		if now.Sub(ts) < cfg.Window {
			kept = append(kept, ts)
		}
	}
	kept = append(kept, now)
	g.capacityRejectStrikes[modelID] = kept

	// Active cooldown: record only — never extend or re-arm (see doc above).
	if e, ok := g.capacityCooldowns[modelID]; ok && now.Before(e.expiry) {
		return false
	}

	trips := g.capacityCooldownTrips[modelID]
	// A fresh pair (trips == 0) needs the full threshold inside the window. A
	// half-open pair (trips > 0: tripped before, no accept since, cooldown
	// expired → this reject IS the failed re-probe) re-arms immediately.
	if trips == 0 && len(kept) < cfg.Threshold {
		return false
	}

	// Arm/re-arm: fresh entry with an unclaimed probe slot for the NEXT expiry.
	g.capacityCooldowns[modelID] = &capacityCooldownEntry{expiry: now.Add(capacityCooldownBackoff(cfg, trips))}
	g.capacityCooldownTrips[modelID] = trips + 1
	return true
}
