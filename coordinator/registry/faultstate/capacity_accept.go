package faultstate

import "time"

// CapacityAccept keeps the original gate reference across the caller's optional
// live-budget snapshot. It contains no acquired lock. Apply validates the
// reference after acquiring the gate, including identity changes in that gap.
type CapacityAccept[C comparable] struct {
	owner            *Manager[C]
	ref              gateRef[C]
	model            string
	observedAt       time.Time
	countRateOutcome bool
	hasClamp         bool
}

func (r *Manager[C]) PrepareCapacityAccept(providerID, modelID string, observedAt time.Time, countRateOutcome bool) (CapacityAccept[C], bool) {
	if providerID == "" || modelID == "" {
		return CapacityAccept[C]{}, false
	}
	ref := r.lookupSessionGateRef(providerID)
	if ref.g == nil {
		if !countRateOutcome || r.capacityRateCfg.PenaltyMs <= 0 {
			return CapacityAccept[C]{}, false
		}
		ref = r.gateForSession(providerID)
	}
	ref, hasClamp := r.refHasPairState(ref, gateFlagBudgetClamp)
	return CapacityAccept[C]{owner: r, ref: ref, model: modelID, observedAt: observedAt, countRateOutcome: countRateOutcome, hasClamp: hasClamp}, true
}

func (a CapacityAccept[C]) NeedsBudgetSnapshot() bool { return a.hasClamp }

func (a CapacityAccept[C]) Apply(heartbeatAt time.Time, rawRemaining int64, budgetReported bool) (rateOutcomeRecorded bool) {
	r, ref, modelID, observedAt, countRateOutcome := a.owner, a.ref, a.model, a.observedAt, a.countRateOutcome

	hold := r.lockGate(ref, "capacity_accept")
	defer hold.unlock()
	g := hold.g
	if g == nil {
		return false
	}

	now := r.now()
	if observedAt.IsZero() || observedAt.After(now) {
		observedAt = now
	}
	if strikes := g.capacityRejectStrikes[modelID]; len(strikes) > 0 {
		kept := strikes[:0]
		for _, stamp := range strikes {
			if stamp.After(observedAt) {
				kept = append(kept, stamp)
			}
		}
		if len(kept) == 0 {
			delete(g.capacityRejectStrikes, modelID)
		} else {
			g.capacityRejectStrikes[modelID] = kept
		}
	}
	g.rebuildCapacityCooldownLocked(r.capacityCooldownCfg, modelID)
	// Gray-box trackers: the accept is PROOF for the clamp's release condition
	// (b) — never an instant release, which still needs a strictly-fresher
	// heartbeat with meaningful headroom — and ONE served outcome for the rate
	// window (which deliberately has NO reset semantics: the accept/reject mix
	// IS the signal). Then drop the entry if it is now inactive (this accept
	// completed the release proof, the TTL lapsed, or it was armed budgetless):
	// a lingering inactive entry would keep re-blocking the identity's next
	// budgetless reconnect window. The snapshot was read before the gate was
	// taken (lock order p.mu → gate.mu), so two benign races exist: a clamp
	// armed in between sees a zero snapshot and keeps holding, and a heartbeat
	// delivered in between already ran its own release pass before
	// acceptedSince was set, so the release lands on the NEXT heartbeat or
	// accept. Neither can release early.
	if e, hasClamp := g.budgetClamps[modelID]; hasClamp {
		if !e.clampedAt.After(observedAt) {
			e.acceptedSince = true
		}
		g.dropInactiveBudgetClampLocked(r.budgetClampCfg, modelID, heartbeatAt, rawRemaining, budgetReported, now)
	}
	if countRateOutcome {
		rateOutcomeRecorded = g.recordCapacityRateAcceptLocked(r.capacityRateCfg, modelID, now)
	}
	g.ejectionCapacityStreak = capacityStreak{}
	if g.ejectionLastTripCapacity {
		g.ejectionTrips = 0
		g.ejectionLastTripCapacity = false
	}
	g.updatedLocked(now)
	return rateOutcomeRecorded
}
