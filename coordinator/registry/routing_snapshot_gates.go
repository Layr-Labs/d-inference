package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// snapshotProviderIntoLockedEx builds a routing snapshot for p into
// caller-owned storage, returning ok=false and the closed GateReason when p
// fails any structural/privacy/capacity/trait gate. selfRouteOwner is true
// when this is a self-route request and p is owned by the requesting account:
// it (1) drops the hardware-trust floor to TrustNone — a personal Mac will not
// be MDM/MDA enrolled, so without this it would be unroutable to its own owner
// — and (2) admits a private-only machine, which is otherwise excluded from
// the public fleet. Every privacy-critical gate (RuntimeVerified, private-text
// support, challenge freshness) still applies. traits carry the request shape
// into the shape-keyed inference-error cooldown and the render-broken /
// version-floor eligibility gates. ignoreProviderBreaker is threaded into the
// routing gate: only the selectBestCandidateLockedFull fail-open fallback pass
// sets it true. now is the scan clock: hot-path callers walk the whole fleet
// and must read the wall clock ONCE per scan, not once per provider; every
// time-keyed gate (challenge freshness, cooldowns, breaker, clamp) evaluates
// against that single instant.
//
// Writes into caller-owned storage instead of returning the (large) snapshot
// by value, and names WHICH gate dropped a failing provider. The fleet walks
// (scanCandidatesLocked, PredictServable) and the fleet sampler
// (slotEligibilityReasonLocked) hand it the final resting place of the
// snapshot — a candidate-arena slot or a reused buffer — so a routable
// provider's snapshot is written exactly once and never copied
// (routingSnapshot is ~600 bytes; the per-provider return + candidate copies
// were ~9% of the fleet-scale scan). On a gate failure it returns (false, the
// closed GateReason that dropped p) WITHOUT touching *dst; on success *dst is
// fully overwritten — including hbAgeMs, stamped from the threaded now so the
// system-profiler record carries the heartbeat age the scan actually saw —
// and the reason is GateReasonCount.
func (r *Registry) snapshotProviderIntoLockedEx(dst *routingSnapshot, p *Provider, model string, traits RequestTraits, selfRouteOwner bool, ignoreProviderBreaker bool, now time.Time) (bool, GateReason) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return r.snapshotProviderIntoPLockedEx(dst, p, model, traits, selfRouteOwner, ignoreProviderBreaker, now)
}

// snapshotProviderIntoPLockedEx is snapshotProviderIntoLockedEx for a caller
// that ALREADY holds p.mu — the reservation commit and the plan consumption,
// which take the snapshot, rebuild the cost, compare and debit inside one p.mu
// section so nothing can change the provider in between. Caller holds r.mu
// (either mode) and p.mu.
func (r *Registry) snapshotProviderIntoPLockedEx(dst *routingSnapshot, p *Provider, model string, traits RequestTraits, selfRouteOwner bool, ignoreProviderBreaker bool, now time.Time) (bool, GateReason) {
	if ok, reason := r.providerRoutingGateReasonLockedEx(p, model, traits, selfRouteOwner, now, ignoreProviderBreaker, false); !ok {
		return false, reason
	}

	r.fillRoutingSnapshotPLocked(dst, p, model, now)
	// Heartbeat age from the scan clock (system-profiler record); a zero
	// LastHeartbeat saturates rather than reading as "fresh".
	dst.HBAgeMs = heartbeatAgeMs(now, p.LastHeartbeat)

	// Concurrency headroom with the quality-concurrency cap: a slow model whose
	// quality batch is below the flat fallback (e.g. Gemma at ~14 tok/s solo →
	// batch 1-2) stops being admittable once it is at its quality cap, so load
	// spreads across boxes instead of collapsing a few. The cap resolves the
	// model's own static solo rate internally (solo median / seed → provider
	// benchmark fallback) — NOT dst.decodeTPS, which stays the provider-level
	// rate for TTFT/cost estimation, and NOT the observed-under-load value.
	// No-op (legacy flat cap) when the cap is disabled.
	dst.HasHeadroom = r.hasConcurrencyHeadroomForModelCapResolvedLocked(p, model)
	return true, GateReasonCount
}

// heartbeatAgeMs is now − lastHeartbeat in milliseconds, clamped to int32
// (a zero LastHeartbeat saturates rather than producing a nonsense value).
func heartbeatAgeMs(now, lastHeartbeat time.Time) int32 {
	if lastHeartbeat.IsZero() {
		return clampMsInt32(int64(^uint32(0) >> 1))
	}
	return clampMsInt32(now.Sub(lastHeartbeat).Milliseconds())
}

// backendFreeForLoadGB returns the provider-reported free_for_load_gb (nil-safe).
// Caller must hold the provider lock when passing p.BackendCapacity.
func backendFreeForLoadGB(bc *protocol.BackendCapacity) *float64 {
	if bc == nil {
		return nil
	}
	return bc.FreeForLoadGB
}
