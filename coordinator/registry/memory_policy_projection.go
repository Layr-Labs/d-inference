package registry

import memorypolicy "github.com/eigeninference/d-inference/coordinator/internal/registry/memorypolicy"

func memoryPolicySnapshot(s *routingSnapshot) *memorypolicy.Input {
	return &memorypolicy.Input{
		Model: s.model, ModelLoaded: s.modelLoaded, AvailableOnDisk: s.availableOnDisk,
		TotalPending: s.totalPending, PendingMaxTokens: s.pendingMaxTokens,
		PendingMaxTokensAllModels: s.pendingMaxTokensAllModels,
		PendingMaxBytesAllModels:  s.pendingMaxBytesAllModels, PendingBytesKnown: s.pendingBytesKnown,
		ActiveTokenBudgetUsed: s.activeTokenBudgetUsed, ActiveTokenBudgetMax: s.activeTokenBudgetMax,
		QueuedTokenBudget: s.queuedTokenBudget, MaxTokensPotential: s.maxTokensPotential,
		KVBytesPerToken: s.kvBytesPerToken, PooledTokenBudget: s.pooledTokenBudget,
		BudgetClamped: s.budgetClamped, AutopilotBlocked: s.autopilotBlocked,
		TotalMemoryGB: s.totalMemoryGB, ModelSizeGB: s.modelSizeGB,
		GPUMemoryActiveGB: s.gpuMemoryActiveGB, EstimatedOffloadedMemoryGB: s.estimatedOffloadedMemoryGB,
		FreeForLoadGB: s.freeForLoadGB,
	}
}
