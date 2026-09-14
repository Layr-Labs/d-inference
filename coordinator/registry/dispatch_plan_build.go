package registry

import (
	"github.com/eigeninference/d-inference/coordinator/registry/dispatchplan"
)

// newDispatchPlan builds the plan from the scan that selected winner. One
// bounded pass over the already-built pool: it keeps the
// dispatchPlanMaxAlternates lowest-cost non-winner candidates via insertion
// into a fixed-capacity slice (O(n·8) comparisons, no full-pool sort, no
// full-pool copy — only the ≤8 retained entries copy their ranking terms).
// The scan pool is immutable; live provider identity/state is revalidated when
// an entry is consumed.
func newDispatchPlan(model string, scan candidateScan, winner *routingCandidate) *DispatchPlan {
	plan := &DispatchPlan{}
	// The counts progressively include capacity- and TTFT-rejected candidates
	// that passed the preceding gates in the same immutable scan.
	builder := plan.state.Initialize(model,
		scan.candidateCount+scan.capacityRejections+scan.ttftRejections,
		scan.candidateCount+scan.ttftRejections,
		scan.candidateCount)
	if winner != nil {
		builder.Attempted(winner.provider.ID)
	}
	for _, c := range scan.pool {
		if c == winner {
			continue
		}
		builder.Offer(c.costMs, func() dispatchplan.Retained[*Provider] {
			return dispatchplan.Retained[*Provider]{
				Connection: c.provider,
				View: PlanEntry{
					ProviderID:  c.provider.ID,
					CostMs:      c.costMs,
					TTFTMs:      c.breakdown.TTFTMs,
					RawTTFTMs:   c.breakdown.RawTTFTMs,
					StateMs:     c.breakdown.StateMs,
					ModelLoaded: c.snapshot.ModelLoaded,
					SlotState:   c.snapshot.SlotState,
					ChipFamily:  c.snapshot.ChipFamily,
				},
			}
		})
	}
	return plan
}
