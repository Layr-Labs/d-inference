package memorypolicy

import (
	"github.com/eigeninference/d-inference/coordinator/registry/admission"
)

// Admits returns true when the provider has enough headroom.
// Providers that report a token budget use budget-based admission;
// legacy providers fall back to memory-based estimation.
func Admits(snap *Input, reqPromptTokens, reqMaxTokens int) bool {
	requestTokens := int64(reqPromptTokens) + int64(reqMaxTokens)
	decision := admission.CheckSlot(admission.SlotBudget{
		Blocked: snap.AutopilotBlocked, Clamped: snap.BudgetClamped,
		Used: snap.ActiveTokenBudgetUsed, Queued: snap.QueuedTokenBudget,
		Maximum: snap.ActiveTokenBudgetMax, Potential: snap.MaxTokensPotential,
		Pending: int64(snap.PendingMaxTokens), KVBytesPerToken: snap.KVBytesPerToken,
	}, requestTokens)
	if decision == admission.Reject {
		return false
	}
	if decision == admission.Admit {
		return PoolAdmits(snap, requestTokens)
	}

	// A cold model still spends the same whole-box pool as resident models.
	if !PoolAdmits(snap, requestTokens) {
		return false
	}

	if !snap.ModelLoaded {
		if fits, known := BudgetFits(snap, reqPromptTokens, reqMaxTokens); known && !fits {
			return false
		}
	}

	memory := admission.Memory{
		ModelSizeGB: snap.ModelSizeGB, TotalGB: snap.TotalMemoryGB,
		ActiveGB: snap.GPUMemoryActiveGB, NativeLoadGB: snap.EstimatedOffloadedMemoryGB,
		ModelLoaded: snap.ModelLoaded, AvailableOnDisk: snap.AvailableOnDisk,
		TotalPending: snap.TotalPending, LoadReported: snap.FreeForLoadGB != nil,
	}
	if memory.LoadReported {
		memory.FreeForLoadGB = *snap.FreeForLoadGB
	}
	return admission.MemoryAdmits(memory, requestTokens)
}
