package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// RecordCapacityReject records one capacity-class rejection (token budget /
// KV headroom / queue full / draining / …) for the (provider, model) pair.
// The api layer classifies which provider errors qualify
// (isCapacityRejectStrike) — request-shape context overflows never reach here.
//
// Returns true ONLY on the transition into cooldown so callers can emit the
// capacity_cooldown_tripped metric/log without double-counting. Trip
// conditions:
//   - fresh pair (never tripped, or accept-cleared): Threshold strikes inside
//     Window with zero interleaved accepts;
//   - half-open pair (tripped before, cooldown expired, still no accept): the
//     FIRST post-expiry reject re-arms immediately with doubled backoff.
//
// While a cooldown is ACTIVE, strikes are still recorded (in-flight stragglers
// dispatched before the trip land here) but never extend or re-arm it —
// otherwise stragglers could push recovery out indefinitely.
//
// This is the DERATING entry point: a genuine capacity/token-budget 503 feeds
// all three trackers, including the gray-box capacity-503 rate window
// (faultstate/capacity_rate.go). A benign cold "model not loaded" lazy-load miss must go
// to RecordCapacityRejectLifecycle instead so it does NOT derate the rate, and
// a provably request-deterministic reject (oversized prompt — identical
// fleet-wide) must go to RecordCapacityRejectRequestShape so it arms NO
// gray-box state at all.
func (r *Registry) RecordCapacityReject(providerID, modelID string) (tripped bool) {
	return r.recordCapacityReject(providerID, modelID, true, true)
}

// RecordCapacityRejectLifecycle records a BENIGN lifecycle capacity miss — a
// cold "model not loaded" lazy-load 404 on first touch, or the identical miss
// after the 1h idle-unload (the normal fleet re-warm cycle). It feeds ONLY the
// black-hole cooldown: a box that 404s FOREVER with zero accepts is still a
// black hole, caught by the zero-interleaved-accepts discriminator.
//
// It arms NEITHER gray-box tracker. Not the rate window (no accept-reset, so
// counting normal reload misses would accumulate a false reject rate) — and
// not the budget clamp either: the lifecycle classification takes PRECEDENCE
// over whatever the budget snapshot says. A provider that idle-unloaded the
// model AFTER its last heartbeat still SHOWS the slot budget in the stale
// snapshot, so keying the exemption on snapshot budgetless-ness (arming a
// "budgetless" entry) would arm a REAL gating clamp from a routine re-warm
// 404 — and with the clamp blocking dispatch, no accept could land to prove
// release, stranding the pair until TTL. A cold miss is a statement about
// model residency, never about token-budget honesty, so it must not touch the
// clamp regardless of the snapshot. The api layer routes cold "not loaded"/
// "no model loaded" rejections here; genuine capacity/token-budget 503s go to
// RecordCapacityReject and feed everything.
func (r *Registry) RecordCapacityRejectLifecycle(providerID, modelID string) (tripped bool) {
	return r.recordCapacityReject(providerID, modelID, false, false)
}

// RecordCapacityRejectRequestShape records a capacity-vocabulary rejection the
// api layer has PROVEN request-deterministic — a "batch token budget" reject
// from a provider whose reported budget is not below the model context, so the
// binding term was the model context and every provider rejects the same
// prompt identically (classifyRejection: rejectionDeterministicUnservable).
// Such a reject indicts the REQUEST, not the provider: it must arm NEITHER the
// one-shot budget clamp NOR the no-reset rate window, or a single oversized
// prompt would clamp/derate a healthy pair (and, for the clamp, block the very
// dispatches whose accepts prove release).
//
// It still counts a cooldown STRIKE, deliberately: isCapacityRejectStrike
// includes "batch token budget" because a box misreporting a huge budget
// rejects NORMAL prompts with exactly this string — and such a box classifies
// as request-deterministic here too (its advertised budget >= context IS the
// lie). The cooldown's zero-interleaved-accepts discriminator is what makes
// that safe for healthy pairs (threshold 5 in 60s with NO accept; any accept
// resets the streak), a safety the clamp and rate window by design lack.
func (r *Registry) RecordCapacityRejectRequestShape(providerID, modelID string) (tripped bool) {
	return r.recordCapacityReject(providerID, modelID, false, false)
}

// RecordCapacityRejectBusy records a typed admission-timeout capacity signal
// (InferenceErrorMessage terminal_cause=admission_timeout): the provider
// accepted the dispatch but its engine could not admit the request before the
// admission lease expired — a healthy-but-busy statement, never a fault and
// never a token-budget-honesty statement. It feeds ONLY the black-hole
// cooldown strike (the zero-interleaved-accepts discriminator keeps a serving
// box safe): a pair that admission-times-out EVERYTHING with zero accepts is
// a routing black hole exactly like a 100%-capacity-rejecting one. It arms
// NEITHER gray-box tracker — not the budget clamp (an admission timeout says
// nothing about the reported token budget, and a false clamp blocks the very
// dispatches whose accepts prove release) and not the no-accept-reset
// capacity-503 rate window (transient load would accumulate a false reject
// rate against a healthy pair).
func (r *Registry) RecordCapacityRejectBusy(providerID, modelID string) (tripped bool) {
	return r.recordCapacityReject(providerID, modelID, false, false)
}

// RecordCapacityAccept records that the (provider, model) pair ACCEPTED work —
// the api layer calls it on the first content-bearing chunk (commit) and on
// clean completion. It clears the pair's reject streak, any active cooldown,
// and the exponential-backoff trip count: an accept proves the pair admits
// work, which is exactly the discriminator that separates a busy-but-serving
// box (must NEVER trip) from a black hole (zero accepts). The NODE-level
// capacity streak (faultstate/ejection.go) is cleared for the same reason: a box
// mid-way through a long generation that legitimately sheds concurrent
// dispatches must keep vouching for itself at first content — waiting for the
// completion-time success (RecordProviderServeOutcome) would let transient
// fullness during a long stream masquerade as the zero-accepts black-hole
// signature.
//
// A CAPACITY-shaped ejection's half-open state (trips + last-trip marker) is
// disarmed by the same logic: the half-open instant re-arm exists so a
// black-hole probe that bounces re-ejects in one strike, but a node producing
// content has just disproven the black-hole signature, so a single concurrent
// capacity shed racing the probe must need a full fresh zero-success streak,
// not one strike. A FAULT-shaped ejection's trips are deliberately preserved —
// first content says nothing about fault behavior, and wiping the exponential
// backoff on any served chunk would let a flapping node reset it forever;
// RecordProviderServeOutcome(ok=true) at clean completion is the fault-recovery
// signal. An ACTIVE ejection window (ejectionUntil still in the future) is
// also left untouched: ejection doesn't cancel in-flight work, so content can
// flow from an ejected node, and lifting the quarantine early on it would
// defeat the cooldown — recovery goes through the half-open success probe.
// It returns whether a capacity-503 RATE outcome was recorded for this accept
// (see RecordCapacityAcceptOutcome) so commit-time callers can stamp the request
// (MarkRateOutcomeCounted) and the completion-time accept can decide whether the
// request still owes its one rate outcome.
func (r *Registry) RecordCapacityAccept(providerID, modelID string) (rateOutcomeRecorded bool) {
	return r.RecordCapacityAcceptObserved(providerID, modelID, time.Now(), true)
}

// RecordCapacityAcceptOutcome is RecordCapacityAccept with explicit control
// over the capacity-503 RATE window's denominator (faultstate/capacity_rate.go).
// countRateOutcome=true OFFERS one served-dispatch outcome; whether it was
// actually RECORDED is the return value. While the tracker is enabled, accepts
// are retained even before the first reject so the five-minute denominator is
// independent of event order. The api layer offers at the commit point (first
// content chunk) and stamps the request when the offer recorded
// (MarkRateOutcomeCounted); the completion-time accept re-offers ONLY when the
// commit-time offer did not record (!RateOutcomeCountedSafe), covering paths
// that never commit content without double-counting streamed requests. The
// cooldown/streak/clamp accept semantics below are identical for both values
// (belt-and-braces accepts stay harmless there).
//
// This takes ONLY the identity's gate.mu
// — never r.mu. The one provider read it may need (the live budget snapshot
// that decides whether an accept RELEASES a clamp) happens under p.mu before
// the gate is taken, and only when the gate's flag word says a clamp exists.
func (r *Registry) RecordCapacityAcceptOutcome(providerID, modelID string, countRateOutcome bool) (rateOutcomeRecorded bool) {
	return r.RecordCapacityAcceptObserved(providerID, modelID, time.Now(), countRateOutcome)
}

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
func (r *Registry) recordCapacityReject(providerID, modelID string, deratePair, armClamp bool) (tripped bool) {
	if providerID == "" || modelID == "" {
		return false
	}
	budgetReported := false
	if armClamp {
		budgetReported = providerReportsTokenBudget(r.sessionProvider(providerID), modelID)
	}
	return r.faults.RecordCapacityReject(providerID, modelID, deratePair, armClamp, budgetReported)
}

// RecordCapacityAcceptObserved applies a first-content accept at its original
// observation time. A delayed recorder retains newer strikes, rebuilds their
// cooldown with fresh backoff, and proves clamp release only if observed after
// the clamp was armed. The rate window records apply time to stay ordered.
// All fault-state mutations remain under gate.mu, never the global registry
// lock. A zero or future observation is treated as now.
func (r *Registry) RecordCapacityAcceptObserved(providerID, modelID string, observedAt time.Time, countRateOutcome bool) (rateOutcomeRecorded bool) {
	accept, ok := r.faults.PrepareCapacityAccept(providerID, modelID, observedAt, countRateOutcome)
	if !ok {
		return false
	}
	var heartbeatAt time.Time
	var rawRemaining int64
	var budgetReported bool
	if accept.NeedsBudgetSnapshot() {
		heartbeatAt, rawRemaining, budgetReported = providerBudgetSnapshot(r.sessionProvider(providerID), modelID)
	}
	return accept.Apply(heartbeatAt, rawRemaining, budgetReported)
}

// CapacityCooldownActive reports whether the (provider, model) pair is
// currently quarantined by the capacity-reject cooldown. Exposed for tests and
// observability.
func (r *Registry) CapacityCooldownActive(providerID, modelID string) bool {
	return r.faults.CapacityCooldownActive(providerID, modelID)
}

// CapacityRejectRate exposes the pair's windowed capacity-reject rate and
// sample count for tests and observability.
func (r *Registry) CapacityRejectRate(providerID, modelID string) (rate float64, samples int) {
	return r.faults.CapacityRejectRate(providerID, modelID)
}

// releaseBudgetClampsOnHeartbeat drops any clamp entries for the provider's
// heartbeat-reported models that the just-stamped capacity snapshot proves
// inactive (released / TTL-expired / budgetless-armed). Called from Heartbeat
// AFTER BackendCapacity and LastHeartbeat are written (and after p.mu is
// released), so the accept-then-heartbeat release order cleans up even when
// the pair gets no further traffic — otherwise the released entry would linger
// and re-block the identity's next reconnect before its first heartbeat.
//
// heartbeatAt and capacity are the heartbeat's OWN stamped time and (clamped)
// report, evaluated directly rather than re-read from the provider, so a
// disconnect racing in after the heartbeat cannot void this heartbeat's
// release proof. The common case (no clamp state for the identity) is one
// lock-free flag load; the gate is locked only when an entry exists.
func (r *Registry) releaseBudgetClampsOnHeartbeat(providerID string, heartbeatAt time.Time, capacity *protocol.BackendCapacity) {
	r.faults.ReleaseBudgetClampsOnHeartbeat(providerID, heartbeatAt, capacity)
}

// tryClaimCapacityProbe claims the single half-open probe for an EXPIRED
// cooldown entry, called by the reservation commit (under p.mu, in both
// commit modes) at the moment a request is actually bound to the pair. The
// check and the claim are ONE gate.mu section, so concurrent commits for the
// same identity serialize here even though the commit itself no longer holds
// the registry write lock: the first to reserve the pair claims the probe and
// every later one sees the fresh claim.
//
// Returns false when the pair's gate is CLOSED right now — inside its TTL, or
// expired with another request's probe claim still fresh — so the caller
// rejects the reservation instead of leaking a second probe through the
// post-expiry window. Returns true (a no-op) for a pair with no cooldown entry
// — the overwhelmingly common case, one lock-free flag load — and true after
// claiming an unclaimed or stale slot. nil-safe (a bare Provider has no gate).
//
// The claim is a mutation, so it goes through lockGate like the recorders: a
// rebind that lands between loading p.faultSession and taking the lock moves the
// cooldown entry to the session's new gate, and a claim made on the old
// (emptied) gate would find no entry and admit — a leaked probe through a
// cooled pair. lockGate sees p.faultSession moved and re-resolves. Lock order: the
// caller holds p.mu; gatesMu (on a re-resolve) and gate.mu nest under it.
func (r *Registry) tryClaimCapacityProbe(p *Provider, model string, now time.Time) bool {
	if p == nil {
		return r.faults.TryClaimCapacityProbe(nil, "", model, now)
	}
	return r.faults.TryClaimCapacityProbe(&p.faultSession, p.ID, model, now)
}
