package registry

import (
	"github.com/eigeninference/d-inference/coordinator/registry/routingcost"
)

// HedgeGovernorSnapshot gathers the registry-side inputs the hedge governor
// (api/hedge_governor.go) needs to decide whether launching insurance is
// spending idle capacity or amplifying an overload:
//
//   - idleAlternativeExists: some provider OTHER than the exclusions is an
//     instantly-usable spread target for this request — the same computation
//     as the Phase-0 shadow signal (loadedIdleAlternativeExistsLocked), so
//     the governor and the shadow metric can never disagree on "spare
//     capacity exists";
//   - modelQueueDepth: queued demand for the model whose routing constraints
//     could overlap the capacity available to THIS request (queued consumers
//     outrank insurance — but only consumers that could actually drain onto
//     the pool a hedge would spend; see CompetingQueueDepth for why
//     self-route-only and non-overlapping serial-pinned waiters are out);
//   - fleetIdleSlots: slots with any model resident and zero occupancy,
//     across the publicly-routable fleet, from the same heartbeat
//     BackendCapacity snapshots routing reads — the global concurrent-hedge
//     budget's denominator. Private-only providers are excluded: their idle
//     slots serve exclusively their owner's self-route requests, so they
//     cannot absorb the public demand a hedge displaces and must not mint
//     public hedge budget;
//   - capacitySignalsAvailable: at least one live provider serving the model
//     reports a BackendCapacity snapshot (or has proven quote capability).
//     The dual-path switch: on a capacity-SILENT fleet (all-legacy, plan
//     decision 3) the three signals above are structurally zero — the same
//     shape as genuine saturation — so the governor must be BYPASSED there
//     (today's unconditional 50% hedge), never consulted. Deliberately looser
//     than the full gate chain: this is an advisory "are the inputs
//     meaningful?" bit, not an eligibility decision — reserve-time
//     revalidation still applies every gate.
//
// This is a POINT-IN-TIME advisory snapshot, not a reservation: the governor
// only ever uses it to SUPPRESS a hedge, and a hedge launched on state that
// staled a moment later is caught by the plan revalidation gates at reserve
// time. Tolerating that staleness is what lets this run under r.mu.RLock
// (plus per-provider p.mu, the standard order) instead of serializing with
// reservations. Queue depth is read before taking r.mu so q.mu never nests
// inside it (see RequestQueue.PreferWaiterOwners for the ordering rule).
func (r *Registry) HedgeGovernorSnapshot(model string, pr *PendingRequest, excludeIDs ...string) (idleAlternativeExists bool, modelQueueDepth int, fleetIdleSlots int, capacitySignalsAvailable bool) {
	if q := r.Queue(); q != nil {
		modelQueueDepth = q.CompetingQueueDepth(model, pr)
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	if pr != nil {
		idleAlternativeExists = r.loadedIdleAlternativeExistsLocked(model, pr, nil, excludeIDs...)
	}
	for _, p := range r.providers {
		p.mu.Lock()
		if p.Status != StatusUntrusted && p.Status != StatusOffline {
			if p.BackendCapacity != nil && !p.PrivateOnly {
				for _, slot := range p.BackendCapacity.Slots {
					if routingcost.SlotStateModelLoaded(slot.State) && slot.NumRunning == 0 && slot.NumWaiting == 0 {
						fleetIdleSlots++
					}
				}
			}
			// Model-scoped: a reporting provider that cannot serve this model
			// says nothing about whether THIS model's governor inputs are
			// meaningful. The exclusion set is deliberately NOT applied — the
			// primary reporting capacity already proves this is a reporting
			// fleet for the model (dual path is capability-based, not
			// request-sampled).
			if !capacitySignalsAvailable && (p.BackendCapacity != nil || p.capacityQuoteCapable) {
				for _, m := range p.Models {
					if m.ID == model {
						capacitySignalsAvailable = true
						break
					}
				}
			}
		}
		p.mu.Unlock()
	}
	return idleAlternativeExists, modelQueueDepth, fleetIdleSlots, capacitySignalsAvailable
}
