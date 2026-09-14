package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// RecordCapacityReject records a genuine pair-capacity rejection in all three
// trackers. It reports only a transition into cooldown; see
// faultstate.Manager.RecordCapacityReject for classification and backoff rules.
func (r *Registry) RecordCapacityReject(providerID, modelID string) (tripped bool) {
	return r.recordCapacityReject(providerID, modelID, true, true)
}

// RecordCapacityRejectLifecycle records a cold-load or idle-unload miss in the
// pair cooldown only. Routine re-warming does not indict heartbeat budget or
// capacity rate; see faultstate.Manager.RecordCapacityReject.
func (r *Registry) RecordCapacityRejectLifecycle(providerID, modelID string) (tripped bool) {
	return r.recordCapacityReject(providerID, modelID, false, false)
}

// RecordCapacityRejectRequestShape records a proven request-deterministic reject
// as a cooldown strike, without a budget clamp or rate penalty. The zero-accept
// streak still catches misreported budgets; see faultstate.Manager.RecordCapacityReject.
func (r *Registry) RecordCapacityRejectRequestShape(providerID, modelID string) (tripped bool) {
	return r.recordCapacityReject(providerID, modelID, false, false)
}

// RecordCapacityRejectBusy records a typed admission-timeout as a cooldown
// strike only. It leaves both gray-box trackers untouched; see
// faultstate.Manager.RecordCapacityReject.
func (r *Registry) RecordCapacityRejectBusy(providerID, modelID string) (tripped bool) {
	return r.recordCapacityReject(providerID, modelID, false, false)
}

// RecordCapacityAccept records an accept observed now and offers one capacity-rate
// outcome. The return value says whether that outcome was recorded; recovery and
// newer-strike handling live in faultstate.CapacityAccept.Apply.
func (r *Registry) RecordCapacityAccept(providerID, modelID string) (rateOutcomeRecorded bool) {
	return r.RecordCapacityAcceptObserved(providerID, modelID, time.Now(), true)
}

// RecordCapacityAcceptOutcome records an accept observed now, with explicit
// control over its rate-window offer. A completion offers only when first content
// did not record the request outcome; see faultstate.CapacityAccept.Apply.
func (r *Registry) RecordCapacityAcceptOutcome(providerID, modelID string, countRateOutcome bool) (rateOutcomeRecorded bool) {
	return r.RecordCapacityAcceptObserved(providerID, modelID, time.Now(), countRateOutcome)
}

// recordCapacityReject keeps the optional current Provider budget read before
// faultstate.Manager.RecordCapacityReject acquires a gate. Classification flags
// are supplied by the four public adapters; this path never takes r.mu.
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

// RecordCapacityAcceptObserved prepares a gate reference, reads any required
// current Provider budget, then calls faultstate.CapacityAccept.Apply. Preparation
// holds no gate lock across p.mu; Apply revalidates the reference and preserves
// strikes newer than observedAt. A zero or future observation is treated as now.
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

// releaseBudgetClampsOnHeartbeat passes the heartbeat's own accepted timestamp
// and capacity report after p.mu is released. faultstate.Manager.ReleaseBudgetClampsOnHeartbeat
// uses that report even if the connection disconnects before the release pass.
func (r *Registry) releaseBudgetClampsOnHeartbeat(providerID string, heartbeatAt time.Time, capacity *protocol.BackendCapacity) {
	r.faults.ReleaseBudgetClampsOnHeartbeat(providerID, heartbeatAt, capacity)
}

// tryClaimCapacityProbe uses the actual Provider session under the caller's
// p.mu, then delegates the atomic half-open claim to faultstate.Manager.TryClaimCapacityProbe.
// A missing binding is permissive; an active cooldown or fresh claim rejects.
func (r *Registry) tryClaimCapacityProbe(p *Provider, model string, now time.Time) bool {
	if p == nil {
		return r.faults.TryClaimCapacityProbe(nil, "", model, now)
	}
	return r.faults.TryClaimCapacityProbe(&p.faultSession, p.ID, model, now)
}
