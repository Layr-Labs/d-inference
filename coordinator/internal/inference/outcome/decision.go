package outcome

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/cacheusage"
	providerdispatch "github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// RecordDecision snapshots the real reservation and submits its route record;
// bounded plan retries report zero scans, while full scans retain their cost.
func (s *Recorder) RecordDecision(in providerdispatch.Input, provider *registry.Provider, pr *registry.PendingRequest, requestID string, attempt int, decision registry.RoutingDecision, dispatchErr, outcomeOverride string) {
	if requestID == "" && pr != nil {
		requestID = pr.RequestID
	}
	providerID := ""
	if provider != nil {
		providerID = provider.ID
	} else if decision.ProviderID != "" {
		providerID = decision.ProviderID
	}
	outcome := outcomeOverride
	if outcome == "" {
		switch {
		case providerID != "":
			outcome = "selected"
		case dispatchErr == providerdispatch.ModelTooLarge:
			outcome = "model_too_large"
		case dispatchErr == providerdispatch.TTFTTooSlow:
			outcome = "ttft_429"
		case dispatchErr == "no provider available":
			outcome = "no_provider"
		default:
			outcome = "error"
		}
	}
	keyID := ""
	if pr != nil {
		keyID = pr.KeyID
	}
	if decision.ScanCount > 0 {
		s.Observation.Count("routing.scans", int64(decision.ScanCount), []string{"model:" + in.Model, "outcome:" + outcome})
	}
	record := &store.InferenceRouteRecord{
		RequestID: requestID, Attempt: attempt, ProviderID: providerID,
		Model: in.Model, PublicModel: in.PublicModel, ConsumerKeyHash: store.HashKey(in.ConsumerKey), KeyID: keyID,
		Outcome: outcome, CostMs: decision.CostMs, StateMs: decision.StateMs, QueueMs: decision.QueueMs,
		PendingMs: decision.PendingMs, BacklogMs: decision.BacklogMs, ThisReqMs: decision.ThisReqMs,
		HealthMs: decision.HealthMs, TTFTMs: decision.TTFTMs, BestTTFTMs: decision.BestTTFTMs,
		EffectiveQueue: decision.EffectiveQueue, CandidateCount: decision.CandidateCount,
		CapacityRejections: decision.CapacityRejections, ModelTooLargeRejections: decision.ModelTooLargeRejections,
		VisionRejections: decision.VisionRejections, TTFTRejections: decision.TTFTRejections,
		EffectiveTPS: decision.EffectiveTPS, StaticTPS: decision.StaticTPS,
		EstimatedPromptTokens: in.EstimatedPromptTokens, RequestedMaxTokens: in.RequestedMaxTokens,
		RequiresVision: in.RequiresVision, HasTools: in.Traits.HasTools,
		SelfRouteOnly: in.Scope.SelfRouteOnly, PreferOwner: in.Scope.PreferOwner,
		CreatedAt: time.Now(), UpdatedAt: time.Now(),
	}
	if provider != nil {
		provider.Mu().Lock()
		record.ProviderStatus = string(provider.Status)
		record.ProviderTrustLevel = string(provider.TrustLevel)
		record.ProviderVersion = provider.Version
		record.HardwareChip = provider.Hardware.ChipName
		record.HardwareChipFamily = provider.Hardware.ChipFamily
		record.HardwareTier = provider.Hardware.ChipTier
		record.MemoryGB = provider.Hardware.MemoryGB
		record.GPUCores = provider.Hardware.GPUCores
		record.CPUCores = provider.Hardware.CPUCores.Total
		record.SystemMemoryPressure = provider.SystemMetrics.MemoryPressure
		record.SystemCPUUsage = provider.SystemMetrics.CPUUsage
		record.SystemThermalState = provider.SystemMetrics.ThermalState
		if cap := provider.BackendCapacity; cap != nil {
			record.GPUMemoryActiveGB = cap.GPUMemoryActiveGB
			record.GPUMemoryPeakGB = cap.GPUMemoryPeakGB
			record.GPUMemoryCacheGB = cap.GPUMemoryCacheGB
			for _, slot := range cap.Slots {
				if slot.Model == in.Model {
					record.SlotState = slot.State
					record.BackendRunning = slot.NumRunning
					record.BackendWaiting = slot.NumWaiting
					record.ActiveTokenBudgetUsed = slot.ActiveTokenBudgetUsed
					record.ActiveTokenBudgetMax = slot.ActiveTokenBudgetMax
					record.QueuedTokenBudget = slot.QueuedTokenBudget
					break
				}
			}
		}
		provider.Mu().Unlock()
	}
	// Shadow measurements remain synchronous; persistence uses the existing sink.
	s.Metrics.TTFTShadow(in.Model, decision)
	if decision.CacheDiscountMs > 0 {
		s.Observation.Incr("routing.cache_evaluation", []string{
			"mode:active", "tier:" + cacheusage.LowCardinalityTier(decision.CacheTier),
		})
	}
	s.Observation.SubmitRouteRecord(record)
}
