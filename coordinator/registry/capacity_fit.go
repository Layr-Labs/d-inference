package registry

import "math"

// A fit bias must preserve fleet spread. A hard best-fit rule monopolizes the
// smallest class whenever requests complete between arrivals; bounding the
// rendezvous weight at 2 gives a constrained machine at most twice an otherwise
// equivalent machine's share.
const maxStructuralFitWeight = 2.0

// routingStructuralFit returns the provider's structural token size class.
// Admission has already established that the request fits now; the ceiling
// describes how scarce this provider's ability to serve larger future requests
// is. The request check protects callers that construct candidates directly.
func routingStructuralFit(snap routingSnapshot, requestTokens int64) (int64, bool) {
	budget, known := snapshotStructuralBudget(snap)
	if !known || requestTokens < 0 || budget < requestTokens {
		return 0, false
	}
	return budget, true
}

// selectCandidateByStructuralFit performs bounded, weighted rendezvous selection
// only after latency, queue, pending, and cache policy have declared candidates
// equivalent. Request paths already assign random UUIDs, so hashing the
// request/provider pair gives stable per-request choice and fleet-wide spread
// without mutable scheduler state.
//
// When every candidate has a known structural token ceiling, smaller sufficient
// ceilings receive more weight. When every ceiling is unknown, total RAM is the
// size-class fallback. Mixed knowledge is uniform so a modern report cannot
// accidentally starve a legacy provider.
func selectCandidateByStructuralFit(
	candidates []*routingCandidate,
	requestID string,
) *routingCandidate {
	if len(candidates) == 0 {
		return nil
	}
	if len(candidates) == 1 {
		return candidates[0]
	}

	known := 0
	maxCapacity := int64(0)
	maxRAM := 0.0
	allRAMKnown := true
	for _, candidate := range candidates {
		if candidate.fitKnown {
			known++
			if candidate.fitCapacityTokens > maxCapacity {
				maxCapacity = candidate.fitCapacityTokens
			}
		}
		if candidate.snapshot.totalMemoryGB <= 0 {
			allRAMKnown = false
		} else if candidate.snapshot.totalMemoryGB > maxRAM {
			maxRAM = candidate.snapshot.totalMemoryGB
		}
	}

	weight := func(candidate *routingCandidate) float64 {
		ratio := 1.0
		switch {
		case known == len(candidates) &&
			candidate.fitCapacityTokens > 0 &&
			maxCapacity > 0:
			ratio = math.Sqrt(float64(maxCapacity) /
				float64(candidate.fitCapacityTokens))
		case known == 0 &&
			allRAMKnown &&
			candidate.snapshot.totalMemoryGB > 0 &&
			maxRAM > 0:
			ratio = math.Sqrt(maxRAM / candidate.snapshot.totalMemoryGB)
		}
		if ratio > maxStructuralFitWeight {
			return maxStructuralFitWeight
		}
		if ratio < 1 || math.IsNaN(ratio) || math.IsInf(ratio, 0) {
			return 1
		}
		return ratio
	}

	var selected *routingCandidate
	bestScore := math.Inf(1)
	bestID := ""
	for i, candidate := range candidates {
		id := ""
		if candidate.provider != nil {
			id = candidate.provider.ID
		}
		unit := routingTieUnit(requestID, id, i)
		score := -math.Log(unit) / weight(candidate)
		if score < bestScore ||
			(score == bestScore && (bestID == "" || id < bestID)) {
			selected = candidate
			bestScore = score
			bestID = id
		}
	}
	return selected
}

// routingTieUnit is allocation-free FNV-1a over (request ID, provider ID). The
// top 53 bits map to the open interval (0,1), suitable for weighted rendezvous.
// index distinguishes pointer-only candidates in unit tests; registered
// candidates carry a provider ID, so map iteration order cannot matter.
func routingTieUnit(requestID, providerID string, index int) float64 {
	const (
		offset64 = uint64(14695981039346656037)
		prime64  = uint64(1099511628211)
		two53    = float64(1 << 53)
	)
	hash := offset64
	add := func(value string) {
		for i := 0; i < len(value); i++ {
			hash ^= uint64(value[i])
			hash *= prime64
		}
		hash ^= 0xff
		hash *= prime64
	}
	add(requestID)
	add(providerID)
	if providerID == "" {
		for shift := 0; shift < 64; shift += 8 {
			hash ^= uint64(byte(uint64(index) >> shift))
			hash *= prime64
		}
	}
	return (float64(hash>>11) + 0.5) / two53
}
