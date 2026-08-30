package registry

import "math"

// preferOccupancyDeadlineCandidates makes the enforce mode a fail-open routing
// preference, never a rejection source. It uses the same occupancy-aware raw
// predictor as shadow mode so a candidate whose in-flight work consumes the
// remaining first-content budget yields to a candidate predicted to fit.
//
// Unknown estimates are always retained. If no known candidate fits, only the
// minimum known prediction is retained alongside unknowns: the request still
// dispatches, but the first attempt goes to the provider with the best measured
// chance instead of optimizing completion cost for work that cannot start.
func preferOccupancyDeadlineCandidates(
	candidates []*routingCandidate,
	pr *PendingRequest,
) []*routingCandidate {
	if ttftAdmissionMode != TTFTAdmissionEnforce ||
		pr == nil ||
		pr.RequiresVision ||
		pr.MaxTTFTMs <= 0 ||
		len(candidates) < 2 {
		return candidates
	}

	type prediction struct {
		candidate *routingCandidate
		ms        float64
		known     bool
	}
	predictions := make([]prediction, 0, len(candidates))
	knownCount := 0
	fitting := 0
	best := math.Inf(1)
	for _, candidate := range candidates {
		ms := occupancyAwareTTFTMsFromSnapshot(
			candidate.snapshot, pr.EstimatedPromptTokens)
		if ms <= 0 || math.IsNaN(ms) || math.IsInf(ms, 0) {
			predictions = append(predictions, prediction{candidate: candidate})
			continue
		}
		predictions = append(predictions, prediction{
			candidate: candidate,
			ms:        ms,
			known:     true,
		})
		knownCount++
		if ms <= pr.MaxTTFTMs {
			fitting++
		}
		if ms < best {
			best = ms
		}
	}
	if knownCount == 0 {
		return candidates
	}

	// Preserve scan order; downstream selection owns cost ordering and random
	// spreading. The result cannot be empty because known is non-empty and the
	// all-miss branch always keeps at least its minimum.
	out := make([]*routingCandidate, 0, len(candidates))
	for _, prediction := range predictions {
		if !prediction.known ||
			(fitting > 0 && prediction.ms <= pr.MaxTTFTMs) ||
			(fitting == 0 && prediction.ms == best) {
			out = append(out, prediction.candidate)
		}
	}
	if len(out) == 0 {
		return candidates
	}
	return out
}
