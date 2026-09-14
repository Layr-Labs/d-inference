package registry

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/admission"
)

type pooledTokenBudget = admission.Pool

func admissionPolicy() admission.Policy { return admission.NewPolicy(providerVersions) }

func admissionSnapshot(snap *routingSnapshot) admission.Snapshot {
	return admission.Snapshot{
		Model:                     snap.Model,
		BinaryVersion:             snap.BinaryVersion,
		TotalPending:              snap.TotalPending,
		PendingMaxTokens:          snap.PendingMaxTokens,
		PendingMaxTokensAllModels: snap.PendingMaxTokensAllModels,
		PendingMaxBytesAllModels:  snap.PendingMaxBytesAllModels,
		PendingBytesKnown:         snap.PendingBytesKnown,
		MaxTokensPotential:        snap.MaxTokensPotential,
		GPUMemoryActiveGB:         snap.GPUMemoryActiveGB,
		TotalMemoryGB:             snap.TotalMemoryGB,
		FreeForLoadGB:             snap.FreeForLoadGB,
		ModelSizeGB:               snap.ModelSizeGB,
		ModelLoaded:               snap.ModelLoaded,
		AvailableOnDisk:           snap.AvailableOnDisk,
		ActiveTokenBudgetUsed:     snap.ActiveTokenBudgetUsed,
		ActiveTokenBudgetMax:      snap.ActiveTokenBudgetMax,
		QueuedTokenBudget:         snap.QueuedTokenBudget,
		Pool:                      snap.PooledTokenBudget,
		BudgetClamped:             snap.BudgetClamped,
		KVBytesPerToken:           snap.KVBytesPerToken,
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
