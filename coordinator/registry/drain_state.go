package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Drain awareness (R2, coordinator half).
//
// A provider that is draining ahead of a restart/update refuses every new
// dispatch, but until now nothing told routing: its heartbeat kept reporting
// idle/serving with warm slots, so the cost scheduler kept ranking it as an
// ideal instant-TTFT target and each bounce cost the request one of its three
// transient-capacity retries, derated the pair's gray-box capacity-503 rate,
// and armed its budget clamp — for a healthy box that was about to restart.
//
// Wire strings expected from the provider (the Swift half is implemented
// separately; mirror in provider-swift/Sources/ProviderCore/Protocol/):
//
//   - heartbeat `"status": "draining"` (protocol.HeartbeatStatusDraining)
//     while the provider is refusing new work. Any later heartbeat carrying
//     "idle" or "serving" clears the state immediately; a heartbeat that
//     keeps saying "draining" refreshes the TTL.
//   - inference_error `{"failure_code": "capacity", "status_code": 503,
//     "error_reason": "draining"}` (protocol.InferenceErrorReasonDraining) on
//     the drain admission rejection. The api layer marks the provider
//     draining from that terminal too, so a drain the provider announced
//     with a rejection before its event heartbeat landed (the announcement
//     is a detached task and is dropped while the session is not registered)
//     is skipped from the next scan on.
//
// Both markers ship in the same provider binary (released 0.8.16 sends
// neither), so a provider that typed the reason also reports the status and
// its own idle/serving heartbeat is authoritative for either mark: an update
// drain that aborts before its "draining" heartbeat was ever delivered is
// back in routing on its next heartbeat, not after the TTL. Legacy providers
// send neither marker and keep today's path (an untyped 503 sanitized to
// capacity_busy); they never hold a mark. Both markers are additive and
// ignored by older coordinators.
//
// Routing: providerPassesRoutingGatesLockedEx skips a draining provider on
// the same branch as the capacity-reject cooldown, so the candidate scan and
// the admission preflight (quickCapacityCheck) count it as a TRANSIENT
// capacityRejection — an all-draining model surfaces as 429 + Retry-After /
// queue material, never as a "no providers" 503.

// drainStateTTL bounds how long a draining mark is honored without a
// refreshing heartbeat: long enough to outlast the 5 s heartbeat cadence and
// the provider's shutdown path (which restarts the socket anyway), short
// enough that a provider whose drain was aborted but whose heartbeats stopped
// arriving is back in routing within minutes. It is the heartbeat-loss
// fallback; a live provider clears its mark with its next idle/serving.
const drainStateTTL = 150 * time.Second

// providerDrainingLocked reports whether p has an unexpired draining mark.
// Caller holds p.mu.
func providerDrainingLocked(p *Provider, now time.Time) bool {
	return !p.drainingUntil.IsZero() && now.Before(p.drainingUntil)
}

// applyHeartbeatDrainStateLocked updates the draining mark from a heartbeat's
// status string: "draining" (re)arms the TTL, "idle"/"serving" clear the mark
// whoever set it, and any other value (legacy/unknown) leaves it untouched.
// The provider's own status report is authoritative over a mark set by its
// typed rejection: the rejection is only ever emitted by a binary that also
// reports "draining" while it refuses work, so an idle/serving heartbeat
// means the drain is over (see the file header). Caller holds p.mu.
func applyHeartbeatDrainStateLocked(p *Provider, status string, now time.Time) {
	switch status {
	case protocol.HeartbeatStatusDraining:
		p.drainingUntil = now.Add(drainStateTTL)
	case "idle", "serving":
		p.drainingUntil = time.Time{}
	}
}

// MarkDraining marks a live provider draining for drainStateTTL (the typed
// draining rejection path). Returns true only on the transition into the
// draining state so callers can log/meter once. Unknown ids are a no-op.
func (r *Registry) MarkDraining(id string) (transitioned bool) {
	r.mu.RLock()
	p := r.providers[id]
	r.mu.RUnlock()
	if p == nil {
		return false
	}
	now := time.Now()
	p.mu.Lock()
	was := providerDrainingLocked(p, now)
	p.drainingUntil = now.Add(drainStateTTL)
	p.mu.Unlock()
	if !was {
		r.logger.Info("provider draining: routing skips it until it reports idle/serving or the drain TTL lapses",
			"provider_id", id, "ttl", drainStateTTL)
	}
	return !was
}

// ProviderDraining reports whether the provider currently carries an
// unexpired draining mark (false for unknown ids).
func (r *Registry) ProviderDraining(id string) bool {
	r.mu.RLock()
	p := r.providers[id]
	r.mu.RUnlock()
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return providerDrainingLocked(p, time.Now())
}
