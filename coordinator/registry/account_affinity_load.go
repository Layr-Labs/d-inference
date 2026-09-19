package registry

import "math"

func accountAffinityLoadDelayMs(candidate *routingCandidate) float64 {
	delayMs, _ := accountAffinityLoadEstimate(candidate)
	return delayMs
}

// accountAffinityLoadEstimate compares the same machine/model/request under
// its current load with a counterfactual idle machine. Own-prompt prefill cost
// is identical in both, so only queued prefill and incremental first-decode
// contention count toward spillover. An intrinsically slow but idle machine
// has ZERO load penalty, irrespective of any other candidate's speed.
//
// Reuse the live queue estimator (including not-yet-reflected reservations)
// and the decode-quality projection's observed-rate unwind. The calibration
// ratio was captured when this candidate was built: no new calibrator read,
// mutable baseline history, or per-account state. Output-token reservations
// remain memory accounting, never a serial wait for completion.
//
// The second result is the full request estimate for the affinity-only
// deadline check, never lower than the existing live TTFT. Queued prefill is
// already included there and must NOT be added to that estimate again. This
// helper does not change global TTFT admission or enable shadow occupancy.
func accountAffinityLoadEstimate(candidate *routingCandidate) (delayMs, loadedTTFTMs float64) {
	if candidate == nil || !accountAffinityHasKnownTTFT(candidate) ||
		!accountAffinityFinitePositive(candidate.calibrationRatio) {
		return math.Inf(1), math.Inf(1)
	}
	snap := &candidate.snapshot
	prefillTPS := resolvePrefillTPS(snap)
	idleTPS := projectedPerRequestDecodeTPSAtBatch(snap, 0)
	loadedTPS := projectedPerRequestDecodeTPSAtBatch(snap, accountAffinityOccupancy(snap))
	if !accountAffinityFinitePositive(prefillTPS) || !accountAffinityFinitePositive(idleTPS) ||
		!accountAffinityFinitePositive(loadedTPS) {
		return math.Inf(1), math.Inf(1)
	}
	promptTokens := max(0, candidate.pricedPromptTokens)
	queuedTokens := queuedPrefillTokensAhead(snap, promptTokens)
	if queuedTokens < 0 || math.IsNaN(queuedTokens) || math.IsInf(queuedTokens, 0) {
		return math.Inf(1), math.Inf(1)
	}
	queuedMs := queuedTokens / prefillTPS * 1000
	idleDecodeMs, loadedDecodeMs := 1000/idleTPS, 1000/loadedTPS
	delayMs = (queuedMs + math.Max(0, loadedDecodeMs-idleDecodeMs)) * candidate.calibrationRatio
	loadedTTFTMs = (float64(promptTokens)/prefillTPS*1000 + queuedMs + loadedDecodeMs) * candidate.calibrationRatio
	loadedTTFTMs = math.Max(candidate.breakdown.TTFTMs, loadedTTFTMs)
	if math.IsNaN(delayMs) || math.IsInf(delayMs, 0) || !accountAffinityFinitePositive(loadedTTFTMs) {
		return math.Inf(1), math.Inf(1)
	}
	return delayMs, loadedTTFTMs
}
