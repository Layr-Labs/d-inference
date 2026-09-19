package registry

import "github.com/eigeninference/d-inference/coordinator/protocol"

// Negative gauges cannot cancel other slots' work. Saturate the sum so even
// malformed provider reports cannot wrap the soft load estimate back to idle.
func accountAffinityReportedOccupancy(slots []protocol.BackendSlotCapacity) int {
	const maxInt = int(^uint(0) >> 1)
	total := 0
	for _, slot := range slots {
		for _, count := range [...]int{slot.NumRunning, slot.NumWaiting} {
			if count <= 0 {
				continue
			}
			if count > maxInt-total {
				return maxInt
			}
			total += count
		}
	}
	return total
}

// accountAffinityReservationChanged fences the affinity-specific inputs that
// ordinary cost equality does not cover. The caller holds r.mu and the winner's
// p.mu through the final pending debit. The load estimate is a prediction, not
// a promise about the machine's future first-token latency.
func accountAffinityReservationChanged(pr *PendingRequest, scan candidateScan, selected, current *routingCandidate) bool {
	if scan.accountAffinityConfig.Mode != AccountAffinityOn || !scan.accountAffinity.Applied {
		return false
	}
	if current.snapshot.affinityIdentity != selected.snapshot.affinityIdentity ||
		current.breakdown.TTFTMs != selected.breakdown.TTFTMs ||
		accountAffinityLoadDelayMs(current) != accountAffinityLoadDelayMs(selected) ||
		projectedPerRequestDecodeTPSAtBatch(&current.snapshot, accountAffinityOccupancy(&current.snapshot)) !=
			projectedPerRequestDecodeTPSAtBatch(&selected.snapshot, accountAffinityOccupancy(&selected.snapshot)) {
		return true
	}
	return !accountAffinityFeasible(current, pr, scan.accountAffinityConfig)
}
