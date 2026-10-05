package memorypolicy

import "github.com/eigeninference/d-inference/coordinator/internal/registry/kvbudget"

// Input contains only the detached inputs to physical admission.
// The caller must capture and revalidate them under the provider's lock.
type Input struct {
	Model                                                                              string
	ModelLoaded, AvailableOnDisk                                                       bool
	TotalPending, PendingMaxTokens, PendingMaxTokensAllModels                          int
	PendingMaxBytesAllModels                                                           int64
	PendingBytesKnown                                                                  bool
	ActiveTokenBudgetUsed, ActiveTokenBudgetMax, QueuedTokenBudget, MaxTokensPotential int64
	KVBytesPerToken                                                                    int64
	PooledTokenBudget                                                                  kvbudget.Budget
	BudgetClamped, AutopilotBlocked                                                    bool
	TotalMemoryGB, ModelSizeGB, GPUMemoryActiveGB, EstimatedOffloadedMemoryGB          float64
	FreeForLoadGB                                                                      *float64
}
