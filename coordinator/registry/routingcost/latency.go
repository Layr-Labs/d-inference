package routingcost

import (
	"math"
	"time"
)

// RawTTFTMs returns the estimated time-to-first-token in milliseconds
// for a candidate/provider snapshot. It is shared between the preflight
// (QuickCapacityCheckWithTTFTForRequest) and the scheduler
// (buildCandidateWithReason) so the two paths cannot drift on what "TTFT"
// means.
//
// Token-budget fields are admission/memory reservations, not decode work that
// must fully drain before this request can emit a first token. Continuous
// batching lets a newly-admitted request join the decode loop once its prefill
// completes; existing active max-output reservations only slow the next decode
// step, which is already reflected by effectiveTPS. Count waiting prefills ahead
// and this request's own prefill instead of treating active_token_budget_used as
// a serial decode backlog.
func RawTTFTMs[Connection comparable](snap *Snapshot[Connection], reqPromptTokens int) float64 {
	if !snap.HasBackendCapacity {
		return 0
	}
	statePenalty, _ := SlotStatePenalty(snap.SlotState)
	if reqPromptTokens < 0 {
		reqPromptTokens = 0
	}
	prefillTPS := ResolvePrefillTPS(snap)
	if prefillTPS <= 0 {
		prefillTPS = 1.0
	}
	effectiveTPS := ResolveEffectiveTPS(snap)
	if effectiveTPS <= 0 {
		effectiveTPS = 1.0
	}

	queuedPrefillMs := QueuedPrefillTokensAhead(snap, reqPromptTokens) / prefillTPS * 1000.0
	thisPrefillMs := float64(reqPromptTokens) / prefillTPS * 1000.0
	firstDecodeMs := 1000.0 / effectiveTPS
	// NOTE: the Phase-0 occupancy term (Policy.OccupancyMs) is deliberately NOT added
	// here. RawTTFTMs is the LIVE estimate consumed by the routing cost's
	// TTFTMs, the candidate-loop MaxTTFTMs ceiling, and the preflight bestTTFT — so
	// it must stay occupancy-FREE regardless of EIGENINFERENCE_TTFT_OCCUPANCY_ALPHA.
	// The occupancy-aware estimate (base + occupancy term) lives in
	// Policy.OccupancyAwareTTFTMs and is used ONLY by the shadow evaluator.
	return statePenalty + queuedPrefillMs + thisPrefillMs + firstDecodeMs
}

func QueuedPrefillTokensAhead[Connection comparable](snap *Snapshot[Connection], reqPromptTokens int) float64 {
	if reqPromptTokens < 0 {
		reqPromptTokens = 0
	}
	waiting := snap.BackendWaiting
	reflected := snap.BackendRunning + snap.BackendWaiting
	if reflected == 0 && snap.PendingPrefillKnown {
		// The heartbeat contains no same-model work, so current reservations
		// are unreflected. Price their own prompts, excluding attempts that
		// already committed content. Using this request's prompt for every
		// reservation can underprice short-behind-long and overprice the reverse.
		return snap.PendingPrefillTokens + float64(snap.PendingPrefillUnknown)*float64(reqPromptTokens)
	}
	// With reflected work we cannot join heartbeat queue positions to local
	// attempts or know their remaining prefill. Preserve the existing proxy
	// until that evidence exists; do not sum local work on top of it.
	if extraPending := snap.PendingForModel - reflected; extraPending > 0 {
		waiting += extraPending
	}
	if waiting <= 0 {
		return 0
	}
	return float64(waiting) * float64(reqPromptTokens)
}

// CalibratedTTFTMsWithRatio is Policy.CalibratedTTFTMs with the ratio already read,
// so the scheduler can record exactly the ratio it scored with.
func CalibratedTTFTMsWithRatio[Connection comparable](snap *Snapshot[Connection], rawMs float64, ratio float64) float64 {
	if rawMs <= 0 {
		return rawMs
	}
	if ratio == 1.0 {
		return rawMs
	}
	penalty, _ := SlotStatePenalty(snap.SlotState)
	if penalty < 0 || penalty >= rawMs || math.IsInf(penalty, 0) {
		return rawMs
	}
	return penalty + (rawMs-penalty)*ratio
}

// Policy.CalibratedTTFTMs scales the flow portion (queued prefill + this prefill +
// first decode) of a raw RawTTFTMs estimate by the learned
// actual/predicted ratio. The cold-load statePenalty is passed through
// unscaled: it is a load-latency proxy, not part of the throughput model the
// ratio measures, and scaling it would collapse the deliberate cold-route bias
// (e.g. 30s × 0.33 ≈ 10s would let a cold box pass gates it should not).
func (policy *Policy[Connection]) CalibratedTTFTMs(snap *Snapshot[Connection], rawMs float64) float64 {
	return CalibratedTTFTMsWithRatio(snap, rawMs, policy.calibration.appliedRatio(snap.Model, snap.ChipFamily))
}

func (policy *Policy[Connection]) EstimatedTTFT(snap *Snapshot[Connection], reqPromptTokens int) time.Duration {
	ttftMs := RawTTFTMs(snap, reqPromptTokens)
	if ttftMs <= 0 || math.IsNaN(ttftMs) || math.IsInf(ttftMs, 0) {
		return 0
	}
	// Same calibration as the scheduler's gate input (buildCandidateWithReason)
	// so the preflight bestTTFT and the hard-reject ceiling cannot drift.
	ttftMs = policy.CalibratedTTFTMs(snap, ttftMs)
	return time.Duration(ttftMs * float64(time.Millisecond))
}
