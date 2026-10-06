package kvbudget

import "github.com/eigeninference/d-inference/coordinator/protocol"

// TokenTotals reconstructs a provider's pooled token (KV-cache)
// budget from its per-model backend slots, returning used and total token
// budget for that single provider. Each slot's ActiveTokenBudgetMax is the
// private grant assigned by the one-engine runtime's KV re-slicing, so grants
// add across slots; on a single-model provider this reduces to the slot max.
//
// A slot with neither a positive maximum nor a positive KV rate is ignored. A
// positive-rate known-zero slot contributes its live use but no capacity,
// preserving an in-flight commitment after a grant shrink — so used can
// transiently exceed total. Negative values are floored. A nil/empty slice
// yields used=0, total=0.
func TokenTotals(slots []protocol.BackendSlotCapacity) (used, total int64) {
	for _, slot := range slots {
		rate := ClampRate(slot.KVBytesPerToken)
		if slot.ActiveTokenBudgetMax <= 0 && rate <= 0 {
			continue
		}
		slotCommitted := addNonnegativeSaturating(0, slot.ActiveTokenBudgetUsed)
		slotCommitted = addNonnegativeSaturating(slotCommitted, slot.QueuedTokenBudget)
		used = addNonnegativeSaturating(used, slotCommitted)
		total = addNonnegativeSaturating(total, slot.ActiveTokenBudgetMax)
	}
	return used, total
}
