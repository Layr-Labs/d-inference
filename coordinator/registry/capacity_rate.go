package registry

import (
	"sort"
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
	_, existed := r.capacityRateRejects[key]
	r.capacityRateRejects[key] = appendWindowedOutcome(r.capacityRateRejects[key], now)
	if !existed {
		sweepCapacityRateMapLocked(r.capacityRateRejects, now)
	}

	// A pair may have gone quiet long enough for its accept-only history to
	// expire before this first/new reject. Prune it now so repeated routing reads
	// do not keep scanning stale timestamps and the first rate uses only the same
	// five-minute window as the reject side.
	if accepts, ok := r.capacityRateAccepts[key]; ok {
		accepts = pruneWindowedOutcomes(accepts, now)
		if len(accepts) == 0 {
			delete(r.capacityRateAccepts, key)
		} else {
			r.capacityRateAccepts[key] = accepts
		}
	}
}

// recordCapacityRateAcceptLocked appends one served-dispatch outcome for the
// pair and prunes the window. Accepts are retained before, during, and after a
// reject window: a first reject must be divided by all recent dispatch outcomes,
// and accepts that outlive the last reject must remain available to a new burst.
// The rate/penalty read paths still return zero while no reject is in-window, so
// this healthy history is observationally dormant. Returns whether the accept
// was stored so the api layer can stamp the request (MarkRateOutcomeCounted)
// and prevent completion from double-counting it. Caller holds r.mu for write.
func (r *Registry) recordCapacityRateAcceptLocked(key capacityRejectKey, now time.Time) (recorded bool) {
	if r.capacityRateCfg.PenaltyMs <= 0 {
		return false
	}
	_, existed := r.capacityRateAccepts[key]
	r.capacityRateAccepts[key] = appendWindowedOutcome(r.capacityRateAccepts[key], now)
	if !existed {
		sweepCapacityRateMapLocked(r.capacityRateAccepts, now)
	}
	return true
}

// pruneWindowedOutcomes keeps only timestamps strictly inside the sliding
// window. Outcome histories are chronological, so binary search avoids scanning
// a hot pair's whole five-minute history on every accept. Reslicing instead of
// compacting makes steady-state expiry amortized O(1); append occasionally grows
// the backing array and releases the skipped prefix.
func pruneWindowedOutcomes(outcomes []time.Time, now time.Time) []time.Time {
	cutoff := now.Add(-capacityRateWindow)
	first := sort.Search(len(outcomes), func(i int) bool {
		return outcomes[i].After(cutoff)
	})
	if first == 0 {
		return outcomes
	}
	if first == len(outcomes) {
		return outcomes[:0]
	}
	return outcomes[first:]
}

// appendWindowedOutcome slides the chronological window and appends the new
// outcome, reusing the backing array.
func appendWindowedOutcome(outcomes []time.Time, now time.Time) []time.Time {
	return append(pruneWindowedOutcomes(outcomes, now), now)
}

// sweepCapacityRateMapLocked bounds a rate map by dropping pairs whose newest
// outcome has aged out of the window, once the map grows (mirrors the sibling
// cooldown sweeps — churned session-keyed identities are never re-keyed).
// Histories must remain chronological because this deliberately uses the tail
// for an O(1) newest check while holding the registry lock.
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
// chronological slice, so read paths stay safe under r.mu.RLock.
func countInWindow(outcomes []time.Time, now time.Time) int {
	cutoff := now.Add(-capacityRateWindow)
	first := sort.Search(len(outcomes), func(i int) bool {
		return outcomes[i].After(cutoff)
	})
	return len(outcomes) - first
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
	if rejects == 0 {
		return 0, 0
	}
	accepts := countInWindow(r.capacityRateAccepts[key], now)
	total := rejects + accepts
	if total == 0 {
		return 0, 0
	}
	return float64(rejects) / float64(total), total
}
