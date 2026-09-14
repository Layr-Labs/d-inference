package registry

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/admission"
)

type pooledTokenBudget = admission.Pool

func admissionPolicy() admission.Policy { return admission.NewPolicy(providerVersions) }

func admissionSnapshot(snap *routingSnapshot) admission.Snapshot {
	return admission.Snapshot{
		Model:                     snap.model,
		BinaryVersion:             snap.binaryVersion,
		TotalPending:              snap.totalPending,
		PendingMaxTokens:          snap.pendingMaxTokens,
		PendingMaxTokensAllModels: snap.pendingMaxTokensAllModels,
		PendingMaxBytesAllModels:  snap.pendingMaxBytesAllModels,
		PendingBytesKnown:         snap.pendingBytesKnown,
		MaxTokensPotential:        snap.maxTokensPotential,
		GPUMemoryActiveGB:         snap.gpuMemoryActiveGB,
		TotalMemoryGB:             snap.totalMemoryGB,
		FreeForLoadGB:             snap.freeForLoadGB,
		ModelSizeGB:               snap.modelSizeGB,
		ModelLoaded:               snap.modelLoaded,
		AvailableOnDisk:           snap.availableOnDisk,
		ActiveTokenBudgetUsed:     snap.activeTokenBudgetUsed,
		ActiveTokenBudgetMax:      snap.activeTokenBudgetMax,
		QueuedTokenBudget:         snap.queuedTokenBudget,
		Pool:                      snap.pooledTokenBudget,
		BudgetClamped:             snap.budgetClamped,
		KVBytesPerToken:           snap.kvBytesPerToken,
	}
}

func providerPooledTokenBudgetForVersion(slots []protocol.BackendSlotCapacity, version string) pooledTokenBudget {
	return admission.NewPool(slots, slotBudgetLayoutForVersion(version))
}

func clampKVBytesPerToken(rate int64) int64 { return admission.ClampKVBytesPerToken(rate) }
func resolvedPooledKVBytesPerToken(pool *pooledTokenBudget, rate int64) int64 {
	return admission.ResolvedKVBytesPerToken(pool, rate)
}
func knownZeroTokenBudget(maxTokens, rate int64) bool {
	return admission.KnownZeroTokenBudget(maxTokens, rate)
}
func addPooledKVByteCharge(total, tokens, rate int64) int64 {
	return admission.AddByteCharge(total, tokens, rate)
}

func pooledRemainingTokens(pool pooledTokenBudget, pendingTokens int, pendingBytes int64, known bool, rate int64) int64 {
	return admission.RemainingTokens(pool, pendingTokens, pendingBytes, known, rate)
}

func modelFitsHardware(minRAMGB int, sizeGB, totalGB float64) bool {
	return admission.ModelFitsHardware(minRAMGB, sizeGB, totalGB)
}
func reportedFreeForLoadAdmits(sizeGB float64, freeGB *float64) (bool, bool) {
	return admission.ReportedFreeForLoadAdmits(sizeGB, freeGB)
}
func freeMemoryAdmits(snap *routingSnapshot, prompt, maxTokens int) bool {
	view := admissionSnapshot(snap)
	return admissionPolicy().FreeMemoryAdmits(&view, prompt, maxTokens)
}
func snapshotStructuralBudget(snap *routingSnapshot) (int64, bool) {
	view := admissionSnapshot(snap)
	return admissionPolicy().StructuralBudget(&view)
}
