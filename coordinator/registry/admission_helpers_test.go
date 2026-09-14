package registry

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/admission"
)

func providerPooledTokenBudget(slots []protocol.BackendSlotCapacity) pooledTokenBudget {
	return admission.NewPool(slots, sharedSlotHeadroom)
}

func pooledBudgetAdmits(snap *routingSnapshot, requestTokens int64) bool {
	view := admissionSnapshot(snap)
	return admission.PoolAdmits(&view, requestTokens)
}

func coldTokenBudgetEstimate(totalGB, sizeGB float64, rate int64, version, model string) int64 {
	return admissionPolicy().ColdTokenBudgetEstimate(totalGB, sizeGB, rate, version, model)
}

func providerTokenBudget(slots []protocol.BackendSlotCapacity) (used, total int64) {
	return admission.TokenBudget(slots, sharedSlotHeadroom)
}
