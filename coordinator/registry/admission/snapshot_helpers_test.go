package admission

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/providerversion"
)

var testPolicy = NewPolicy(&providerversion.Policy{})

func snapPtr(snap Snapshot) *Snapshot { return &snap }
func poolPtr(pool Pool) *Pool         { return &pool }
func legacyPool(slots []protocol.BackendSlotCapacity) Pool {
	return NewPool(slots, providerversion.SharedSlotHeadroom)
}
func versionedPool(slots []protocol.BackendSlotCapacity, version string) Pool {
	return NewPool(slots, testPolicy.versions.SlotBudgetLayout(version))
}
func legacyTokenBudget(slots []protocol.BackendSlotCapacity) (int64, int64) {
	return TokenBudget(slots, providerversion.SharedSlotHeadroom)
}
