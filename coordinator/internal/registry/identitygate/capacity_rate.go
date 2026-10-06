package identitygate

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
// below the 100-ms first-content fast group and only
// receives traffic when healthier peers are worse. Nothing is ejected — the
// candidate stays in the pool, so the fail-open selection machinery
// (selectBestCandidateLockedFull) is untouched and a degraded-but-only fleet
// still serves. Outcomes age out of the window naturally, so the penalty
// decays on its own once the 503s stop.
//
// One served request counts as ONE accept outcome: the api layer OFFERS the
// accept at the commit point (first content chunk) and stamps the request when
// the offer records; at clean completion it re-offers only when the commit-time
// offer did not record (!RateOutcomeCountedSafe), which covers paths that never
// commit content. Accepts are retained even before the first reject so a later
// reject burst is measured against every recent served dispatch, not against an
// artificially reject-only window. Commit-recorded XOR completion-recorded, so
// the denominator is per-dispatch honest.
// Rejects are recorded once per failed dispatch attempt by
// RecordCapacityReject.
//
// Keyed by the STABLE fault identity like every sibling tracker: the windows
// live on the identity's gate (gate_state.go), so reconnects cannot reset
// them, they migrate on identity rebind (mergeLocked), Disconnect does NOT
// clear them, and the periodic gate sweep drops fully aged windows. Guarded by
// gate.mu.
const (
	// envCapacityRatePenaltyMs scales the penalty (and is the kill switch: 0
	// or negative disables the tracker entirely — no recording, no penalty).
	envCapacityRatePenaltyMs = "EIGENINFERENCE_CAPACITY_RATE_PENALTY_MS"
)

const (
	defaultCapacityRatePenaltyMs = 15_000.0
	// capacityRateWindow is the sliding window outcomes are counted over.
	capacityRateWindow = CapacityRateWindow
	// capacityRateThreshold is the reject rate above which the penalty
	// applies. Below it the pair pays nothing (occasional sheds from a busy
	// box are normal and must stay penalty-free).
	capacityRateThreshold = 0.25
	// capacityRateMinSample is the minimum windowed outcomes
	// (rejects + accepts) before a penalty can apply — a tiny unlucky sample
	// must not derate a healthy pair (fail-open).
	capacityRateMinSample = 8
)

// CapacityRateConfig carries the env-tunable penalty scale, read once at
// Directory construction, mirroring CapacityCooldownConfig.
type CapacityRateConfig struct {
	// PenaltyMs scales the cost penalty: penalty = rate × PenaltyMs once the
	// threshold and minimum sample are met. <= 0 disables (kill switch).
	PenaltyMs float64
}

func LoadCapacityRateConfig() CapacityRateConfig {
	return CapacityRateConfig{
		PenaltyMs: env.EnvFloat(envCapacityRatePenaltyMs, defaultCapacityRatePenaltyMs),
	}
}

// recordCapacityRateRejectLocked appends one capacity-503 outcome for the pair
// and prunes the window. Caller holds g.mu (called from recordCapacityReject).
func (g *State) recordCapacityRateRejectLocked(cfg CapacityRateConfig, model string, now time.Time) {
	if cfg.PenaltyMs <= 0 {
		return
	}
	g.capacityRateHistory.RecordReject(model, now)
}

// recordCapacityRateAcceptLocked appends one served-dispatch outcome for the
// pair and prunes the window. Accepts are retained before, during, and after a
// reject window: a first reject must be divided by all recent dispatch outcomes,
// and accepts that outlive the last reject must remain available to a new burst.
// The rate/penalty read paths still return zero while no reject is in-window, so
// this healthy history is observationally dormant. Returns whether the accept
// was stored so the api layer can stamp the request (MarkRateOutcomeCounted)
// and prevent completion from double-counting it. Caller holds g.mu.
func (g *State) recordCapacityRateAcceptLocked(cfg CapacityRateConfig, model string, now time.Time) (recorded bool) {
	if cfg.PenaltyMs <= 0 {
		return false
	}
	g.capacityRateHistory.RecordAccept(model, now)
	return true
}

// pruneWindowedOutcomes keeps only timestamps strictly inside the sliding
// window. Outcome histories are chronological, so binary search avoids scanning
// a hot pair's whole five-minute history on every accept. Reslicing instead of
// compacting makes steady-state expiry amortized O(1); append occasionally grows
// the backing array and releases the skipped prefix.
func pruneWindowedOutcomes(outcomes []time.Time, now time.Time) []time.Time {
	return PruneWindowedOutcomes(outcomes, now)
}

// appendWindowedOutcome slides the chronological window and appends the new
// outcome, reusing the backing array.
func appendWindowedOutcome(outcomes []time.Time, now time.Time) []time.Time {
	return append(pruneWindowedOutcomes(outcomes, now), now)
}

// countInWindow counts timestamps still inside the window without mutating the
// chronological slice, so read paths stay safe under a shared lock.
func countInWindow(outcomes []time.Time, now time.Time) int {
	return CountInWindow(outcomes, now)
}

// capacityRatePenalty returns the cost penalty (ms) and the measured
// capacity-reject rate for the pair. Penalty is nonzero only when the window
// holds at least capacityRateMinSample outcomes AND the rate exceeds
// capacityRateThreshold; the rate is returned whenever computable so callers
// can expose it for observability.
//
// Hot-path fast exit without the lock: the gate publishes its newest rate
// reject as an atomic, so a healthy pair — no capacity-503 inside the window
// on ANY model — pays nothing (buildCandidateInto runs this once per
// candidate per scan). Only a pair with an in-window reject takes the short
// gate.mu section. nil-safe.
func (g *State) capacityRatePenalty(cfg CapacityRateConfig, model string, now time.Time) (penaltyMs, rate float64) {
	if cfg.PenaltyMs <= 0 || g == nil {
		return 0, 0
	}
	newest := g.newestRateRejectNS.Load()
	if newest == 0 || now.UnixNano()-newest >= int64(capacityRateWindow) {
		return 0, 0
	}
	g = g.lockResolved()
	assessment := g.capacityRateHistory.Assess(model, now)
	g.mu.Unlock()
	return assessment.Penalty(cfg)
}

// RateAssessment is the windowed dispatch evidence used by the routing penalty.
// Accepts remain meaningful even when no rejects remain in the window.
type RateAssessment struct {
	Rejects int
	Accepts int
}

func (a RateAssessment) Penalty(cfg CapacityRateConfig) (penaltyMs, rate float64) {
	if cfg.PenaltyMs <= 0 || a.Rejects == 0 {
		return 0, 0
	}
	total := a.Rejects + a.Accepts
	rate = float64(a.Rejects) / float64(total)
	if total < capacityRateMinSample || rate <= capacityRateThreshold {
		return 0, rate
	}
	return rate * cfg.PenaltyMs, rate
}

// Rate reports only a window with rejects, matching the public rate signal;
// dormant accept-only history remains available in the assessment.
func (a RateAssessment) Rate() (rate float64, samples int) {
	if a.Rejects == 0 {
		return 0, 0
	}
	total := a.Rejects + a.Accepts
	if total == 0 {
		return 0, 0
	}
	return float64(a.Rejects) / float64(total), total
}

// CapacityRateAssessment evaluates the same collection used by routing without
// transferring its mutable histories or locks to the caller.
func (v View) CapacityRateAssessment(model string, now time.Time) RateAssessment {
	if v.g == nil {
		return RateAssessment{}
	}
	g := v.g.lockResolved()
	defer g.mu.Unlock()
	return g.capacityRateHistory.Assess(model, now)
}

// CapacityRejectRate exposes the pair's windowed capacity-reject rate and
// sample count for tests and observability.
func (r *Directory) CapacityRejectRate(providerID, modelID string) (rate float64, samples int) {
	g := r.lookupGateForSession(providerID)
	if g == nil {
		return 0, 0
	}
	now := time.Now()
	g = g.lockResolved()
	assessment := g.capacityRateHistory.Assess(modelID, now)
	g.mu.Unlock()
	return assessment.Rate()
}
