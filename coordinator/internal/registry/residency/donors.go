// Package residency evaluates detached model-load and donor-protection budgets.
package residency

// ResidentBudget records the actual useful residency counted by the planner's
// coverage pass. A non-qualified resident must never incur a fictitious debit.
type ResidentBudget struct {
	Qualified   bool
	Warm, Floor int
}

// ProtectsDonors prices the whole loading transition. Future capacity is not an
// input: it cannot protect a currently needed donor while the GPU is fenced.
func ProtectsDonors(residents []ResidentBudget, contribution, ready, need map[string]float64) bool {
	for _, resident := range residents {
		if resident.Qualified && resident.Warm-1 < resident.Floor {
			return false
		}
	}
	for cohort, debit := range contribution {
		if ready[cohort]-debit+1e-9 < need[cohort] {
			return false
		}
	}
	return true
}

func ProtectedFloor(explicit int, rate float64, requests, shed int) int {
	floor := max(0, explicit)
	if rate > 0 && (requests >= 3 || shed > 0) {
		floor = max(1, floor)
	}
	return floor
}
