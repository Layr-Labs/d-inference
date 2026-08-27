package registry

// routingStructuralFit returns the residual structural token capacity after the
// request. The value is a size class, not live headroom: admission has already
// established that the request fits now, while the structural ceiling describes
// how scarce this provider's ability to serve larger future requests is.
func routingStructuralFit(snap routingSnapshot, requestTokens int64) (int64, bool) {
	budget, known := snapshotStructuralBudget(snap)
	if !known || requestTokens < 0 || budget < requestTokens {
		return 0, false
	}
	return budget - requestTokens, true
}

// narrowCandidatesByStructuralFit performs online best-fit only after latency,
// queue, pending, and cache policy have declared candidates equivalent.
//
// When every candidate has a known structural token ceiling, the smallest
// sufficient residual wins. When every ceiling is unknown, total RAM is the
// conservative size-class fallback. Mixed knowledge stays neutral so a modern
// report cannot accidentally starve a legacy provider.
func narrowCandidatesByStructuralFit(candidates []*routingCandidate) []*routingCandidate {
	if len(candidates) < 2 {
		return candidates
	}

	known := 0
	for _, candidate := range candidates {
		if candidate.fitKnown {
			known++
		}
	}

	switch known {
	case len(candidates):
		best := candidates[0].fitSlackTokens
		for _, candidate := range candidates[1:] {
			if candidate.fitSlackTokens < best {
				best = candidate.fitSlackTokens
			}
		}
		out := make([]*routingCandidate, 0, len(candidates))
		for _, candidate := range candidates {
			if candidate.fitSlackTokens == best {
				out = append(out, candidate)
			}
		}
		return out
	case 0:
		bestRAM := candidates[0].snapshot.totalMemoryGB
		if bestRAM <= 0 {
			return candidates
		}
		for _, candidate := range candidates[1:] {
			if candidate.snapshot.totalMemoryGB <= 0 {
				return candidates
			}
			if candidate.snapshot.totalMemoryGB < bestRAM {
				bestRAM = candidate.snapshot.totalMemoryGB
			}
		}
		out := make([]*routingCandidate, 0, len(candidates))
		for _, candidate := range candidates {
			if candidate.snapshot.totalMemoryGB == bestRAM {
				out = append(out, candidate)
			}
		}
		return out
	default:
		return candidates
	}
}
