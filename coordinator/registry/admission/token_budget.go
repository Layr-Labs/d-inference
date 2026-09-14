package admission

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/providerversion"
)

// TokenBudget reconstructs a provider's true pooled token (KV-cache)
// budget from its per-model backend slots, returning used and total token
// budget for that single provider.
//
// Through v0.7.4, ActiveTokenBudgetMax is the slot's own commitment plus the
// same shared live headroom every co-resident slot observes, so free headroom is
// counted once. The v0.7.5 one-engine release instead reports the private grant
// assigned by runtime KV re-slicing, so free grants add across slots. Both forms
// reduce to the slot max on a single-model provider.
//
// In the legacy layout, slots without a positive maximum are ignored. In the
// v0.7.5 private layout, a positive-rate known-zero slot contributes its live
// use but no capacity, preserving an in-flight commitment after a grant shrink.
// Negative values are floored. A nil/empty legacy slice yields used=0, total=0.
func TokenBudget(slots []protocol.BackendSlotCapacity, layout providerversion.SlotBudgetLayout) (used, total int64) {
	var committed, pooledFree int64
	var privateCapacity int64
	for _, slot := range slots {
		rate := ClampKVBytesPerToken(slot.KVBytesPerToken)
		if slot.ActiveTokenBudgetMax <= 0 && (layout != providerversion.PrivateSlotGrants || rate <= 0) {
			continue
		}
		slotCommitted := addNonnegativeSaturating(0, slot.ActiveTokenBudgetUsed)
		slotCommitted = addNonnegativeSaturating(slotCommitted, slot.QueuedTokenBudget)
		committed = addNonnegativeSaturating(committed, slotCommitted)
		if layout == providerversion.PrivateSlotGrants {
			privateCapacity = addNonnegativeSaturating(
				privateCapacity, slot.ActiveTokenBudgetMax)
			continue
		}
		free := slot.ActiveTokenBudgetMax - slotCommitted
		if free > pooledFree {
			pooledFree = free
		}
	}
	if layout == providerversion.PrivateSlotGrants {
		return committed, privateCapacity
	}
	return committed, addNonnegativeSaturating(committed, pooledFree)
}
