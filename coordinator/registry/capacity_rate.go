package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// Capacity-503 rate penalty — the gray-box derater, the slow half of the
// gray-box fix (see budget_clamp.go for the incident).
//
// A "gray box" fails a material FRACTION of its dispatches with
// capacity-shaped 503s while serving the rest (prod: gemma per-request success
// decayed 57%→25% over 20h on mixed boxes whose heartbeats looked idle). Every
// zero-interleaved-accepts breaker is blind to it by construction: each accept
// resets the pair cooldown streak and the node capacity streak. This tracker
// deliberately has NO accept-triggered reset — that reset IS the blindness
// being fixed. Instead it keeps a sliding window (capacityRateWindow) of
// capacity-503s AND accepts per (stable identity, model) pair and computes
//
//	rate = capacity503s / (capacity503s + accepts)
//
// over the window. When the pair has at least capacityRateMinSample outcomes
// and the rate exceeds capacityRateThreshold, the scheduler adds a cost
// penalty PROPORTIONAL to the rate (rate × EIGENINFERENCE_CAPACITY_RATE_PENALTY_MS,
// default 15000ms) to the pair's candidate in buildCandidateWithReason. A box
// serving 75% fine keeps serving with a mild handicap; a 40%-error box sinks
// well below the near-tie window (nearTieCostWindowMs = 3000) and only
// receives traffic when healthier peers are worse. Nothing is ejected — the
// candidate stays in the pool, so the fail-open selection machinery
// (selectBestCandidateLockedFull) is untouched and a degraded-but-only fleet
// still serves. Outcomes age out of the window naturally, so the penalty
// decays on its own once the 503s stop.
//
// One served request counts as ONE accept outcome: the api layer records the
// accept for this window at the commit point (first content chunk — or, on
// paths that never commit content, at clean completion) and passes
// countRateOutcome=false for the redundant completion-time accept
// (RecordCapacityAcceptOutcome), so the denominator is per-dispatch honest.
// Rejects are recorded once per failed dispatch attempt by
// RecordCapacityReject.
//
// Keyed by the STABLE fault identity like every sibling tracker: reconnects
// cannot reset the window, entries migrate on identity rebind
// (migrateFaultStateLocked), Disconnect does NOT clear them, and the maps are
// bounded by the same opportunistic >1024 sweep. Guarded by r.mu.
const (
	// envCapacityRatePenaltyMs scales the penalty (and is the kill switch: 0
	// or negative disables the tracker entirely — no recording, no penalty).
	envCapacityRatePenaltyMs = "EIGENINFERENCE_CAPACITY_RATE_PENALTY_MS"
)

const (
	defaultCapacityRatePenaltyMs = 15_000.0
	// capacityRateWindow is the sliding window outcomes are counted over.
	capacityRateWindow = 5 * time.Minute
	// capacityRateThreshold is the reject rate above which the penalty
	// applies. Below it the pair pays nothing (occasional sheds from a busy
	// box are normal and must stay penalty-free).
	capacityRateThreshold = 0.25
	// capacityRateMinSample is the minimum windowed outcomes
	// (rejects + accepts) before a penalty can apply — a tiny unlucky sample
	// must not derate a healthy pair (fail-open).
	capacityRateMinSample = 8
)

// capacityRateConfig carries the env-tunable penalty scale, read once at
// Registry construction, mirroring capacityCooldownConfig.
type capacityRateConfig struct {
	// PenaltyMs scales the cost penalty: penalty = rate × PenaltyMs once the
	// threshold and minimum sample are met. <= 0 disables (kill switch).
	PenaltyMs float64
}

func loadCapacityRateConfig() capacityRateConfig {
	return capacityRateConfig{
		PenaltyMs: env.EnvFloat(envCapacityRatePenaltyMs, defaultCapacityRatePenaltyMs),
	}
}

// recordCapacityRateRejectLocked appends one capacity-503 outcome for the pair
// and prunes the window. Caller holds the r.mu write lock (called from
// RecordCapacityReject).
func (r *Registry) recordCapacityRateRejectLocked(key capacityRejectKey, now time.Time) {
	if r.capacityRateCfg.PenaltyMs <= 0 {
		return
	}
	sweepCapacityRateMapLocked(r.capacityRateRejects, now)
	r.capacityRateRejects[key] = appendWindowedOutcome(r.capacityRateRejects[key], now)
}

// recordCapacityRateAcceptLocked appends one served-dispatch outcome for the
// pair and prunes the window. Accepts are recorded only while the pair has a
// capacity-503 inside the window: the penalty math fast-exits at rejects==0
// regardless, so pre-reject accepts add nothing, and skipping them keeps
// RecordCapacityAccept's healthy-pair read-lock fast path intact (a served
// request on a never-rejecting pair never takes the write lock for this).
// Once the reject side has fully decayed, the pair's slices are dropped
// instead — state returns to empty and the fast path is restored. Caller
// holds the r.mu write lock (called from RecordCapacityAccept with
// countRateOutcome=true).
func (r *Registry) recordCapacityRateAcceptLocked(key capacityRejectKey, now time.Time) {
	if r.capacityRateCfg.PenaltyMs <= 0 {
		return
	}
	if countInWindow(r.capacityRateRejects[key], now) == 0 {
		delete(r.capacityRateRejects, key)
		delete(r.capacityRateAccepts, key)
		return
	}
	sweepCapacityRateMapLocked(r.capacityRateAccepts, now)
	r.capacityRateAccepts[key] = appendWindowedOutcome(r.capacityRateAccepts[key], now)
}

// appendWindowedOutcome slides the window (keeps only in-window timestamps)
// and appends the new outcome, reusing the backing array.
func appendWindowedOutcome(outcomes []time.Time, now time.Time) []time.Time {
	kept := outcomes[:0]
	for _, ts := range outcomes {
		if now.Sub(ts) < capacityRateWindow {
			kept = append(kept, ts)
		}
	}
	return append(kept, now)
}

// sweepCapacityRateMapLocked bounds a rate map by dropping pairs whose newest
// outcome has aged out of the window, once the map grows (mirrors the sibling
// cooldown sweeps — churned session-keyed identities are never re-keyed).
func sweepCapacityRateMapLocked(m map[capacityRejectKey][]time.Time, now time.Time) {
	if len(m) <= 1024 {
		return
	}
	for key, outcomes := range m {
		if len(outcomes) == 0 || now.Sub(outcomes[len(outcomes)-1]) >= capacityRateWindow {
			delete(m, key)
		}
	}
}

// countInWindow counts timestamps still inside the window without mutating the
// slice, so read paths stay safe under r.mu.RLock.
func countInWindow(outcomes []time.Time, now time.Time) int {
	n := 0
	for _, ts := range outcomes {
		if now.Sub(ts) < capacityRateWindow {
			n++
		}
	}
	return n
}

// capacityRatePenaltyLocked returns the cost penalty (ms) and the measured
// capacity-reject rate for the pair. Penalty is nonzero only when the window
// holds at least capacityRateMinSample outcomes AND the rate exceeds
// capacityRateThreshold; the rate is returned whenever computable so callers
// can expose it for observability. READ-ONLY — callers hold r.mu in either
// mode (buildCandidateWithReason runs under the selection locks).
func (r *Registry) capacityRatePenaltyLocked(providerID, modelID string, now time.Time) (penaltyMs, rate float64) {
	if r.capacityRateCfg.PenaltyMs <= 0 {
		return 0, 0
	}
	key := capacityRejectKey{ProviderID: r.faultKeyLocked(providerID), ModelID: modelID}
	rejects := countInWindow(r.capacityRateRejects[key], now)
	if rejects == 0 {
		return 0, 0 // hot-path fast exit: healthy pairs pay nothing
	}
	accepts := countInWindow(r.capacityRateAccepts[key], now)
	total := rejects + accepts
	rate = float64(rejects) / float64(total)
	if total < capacityRateMinSample || rate <= capacityRateThreshold {
		return 0, rate
	}
	return rate * r.capacityRateCfg.PenaltyMs, rate
}

// CapacityRejectRate exposes the pair's windowed capacity-reject rate and
// sample count for tests and observability.
func (r *Registry) CapacityRejectRate(providerID, modelID string) (rate float64, samples int) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	now := time.Now()
	key := capacityRejectKey{ProviderID: r.faultKeyLocked(providerID), ModelID: modelID}
	rejects := countInWindow(r.capacityRateRejects[key], now)
	accepts := countInWindow(r.capacityRateAccepts[key], now)
	total := rejects + accepts
	if total == 0 {
		return 0, 0
	}
	return float64(rejects) / float64(total), total
}
