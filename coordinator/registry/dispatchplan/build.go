package dispatchplan

// MaxAlternates bounds retained candidates, probe fanout and outcome buffering.
const MaxAlternates = 8

// Builder initializes a plan at its final address before publication. It must
// not be used after any reader or collector can observe the plan.
type Builder[C comparable] struct{ plan *Plan[C] }

// Initialize starts construction at the owner's final address. Call exactly
// once on a new, unpublished plan; a used Plan must never be copied or reset.
func (dp *Plan[C]) Initialize(model string, eligible, admissible, deadlineFeasible int) Builder[C] {
	dp.model = model
	dp.entries = make([]Retained[C], 0, MaxAlternates)
	dp.attempted = make(map[string]struct{}, MaxAlternates+1)
	dp.eligible = eligible
	dp.admissible = admissible
	dp.deadlineFeasible = deadlineFeasible
	return Builder[C]{plan: dp}
}

// Attempted includes the primary winner in the next refresh's exclusions.
// An empty ID is still an ID; the caller decides whether a winner exists.
func (b Builder[C]) Attempted(providerID string) { b.plan.attempted[providerID] = struct{}{} }

// Offer retains the cheapest bounded tail in one pass. The value projection
// runs only after cost qualifies, with no owner lock or copy of the scan pool.
// Equal costs retain their original scan order.
func (b Builder[C]) Offer(costMs float64, project func() Retained[C]) {
	plan := b.plan
	pos := len(plan.entries)
	for pos > 0 && costMs < plan.entries[pos-1].View.CostMs {
		pos--
	}
	if pos == MaxAlternates {
		return
	}
	if len(plan.entries) < MaxAlternates {
		plan.entries = append(plan.entries, Retained[C]{})
	}
	copy(plan.entries[pos+1:], plan.entries[pos:])
	plan.entries[pos] = project()
}
