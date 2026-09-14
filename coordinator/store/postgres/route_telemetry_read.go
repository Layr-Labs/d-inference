package postgres

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/routerecord"
)

const inferenceRouteSelectColumns = `
			id,
			request_id, attempt, provider_id, model, public_model, consumer_key_hash, key_id, outcome,
			cost_ms, state_ms, queue_ms, pending_ms, backlog_ms, this_req_ms, health_ms, ttft_ms, best_ttft_ms,
			effective_queue, candidate_count, capacity_rejections, model_too_large_rejections, vision_rejections, ttft_rejections,
			effective_tps, static_tps, provider_status, provider_trust_level, provider_version,
			hardware_chip, hardware_chip_family, hardware_tier, memory_gb, gpu_cores, cpu_cores,
			system_memory_pressure, system_cpu_usage, system_thermal_state,
			gpu_memory_active_gb, gpu_memory_peak_gb, gpu_memory_cache_gb,
			slot_state, backend_running, backend_waiting,
			active_token_budget_used, active_token_budget_max, queued_token_budget,
			estimated_prompt_tokens, requested_max_tokens,
			requires_vision, has_tools, self_route_only, prefer_owner,
			final_status, error_code, error_class, prompt_tokens, completion_tokens, reasoning_tokens, cost_micro_usd,
			actual_ttft_ms, dispatch_to_first_chunk_ms, total_duration_ms,
			created_at, updated_at,
			provider_region, consumer_region,
			parse_ms, reserve_ms, route_ms, encrypt_ms, queue_wait_ms, dispatch_ms, actual_decode_tps,
			admitted_but_failed, used_backup, backup_won, error_reason`

// InferenceRouteRecordsSince returns routing records created at or after the
// given time. Zero since returns all records.
func (s *Store) InferenceRouteRecordsSince(since time.Time) []contracts.InferenceRouteRecord {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT `+inferenceRouteSelectColumns+` FROM inference_routes WHERE created_at >= $1 ORDER BY created_at DESC LIMIT $2`,
		since, routerecord.MaxTelemetryReadRows)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var records []contracts.InferenceRouteRecord
	for rows.Next() {
		var r contracts.InferenceRouteRecord
		var id int64
		var finalStatus string
		var errorCode *int
		var errorClass *string
		var errorReason *string
		var promptTokens *int
		var completionTokens *int
		var reasoningTokens *int
		var costMicroUSD *int64
		var actualTTFTMs *float64
		var dispatchToFirstChunkMs *float64
		var totalDurationMs *float64
		var providerRegion *string
		var consumerRegion *string
		var parseMs *float64
		var reserveMs *float64
		var routeMs *float64
		var encryptMs *float64
		var queueWaitMs *float64
		var dispatchMs *float64
		var actualDecodeTPS *float64
		var admittedButFailed *bool
		var usedBackup *bool
		var backupWon *bool

		if err := rows.Scan(
			&id,
			&r.RequestID, &r.Attempt, &r.ProviderID, &r.Model, &r.PublicModel, &r.ConsumerKeyHash, &r.KeyID, &r.Outcome,
			&r.CostMs, &r.StateMs, &r.QueueMs, &r.PendingMs, &r.BacklogMs, &r.ThisReqMs, &r.HealthMs, &r.TTFTMs, &r.BestTTFTMs,
			&r.EffectiveQueue, &r.CandidateCount, &r.CapacityRejections, &r.ModelTooLargeRejections, &r.VisionRejections, &r.TTFTRejections,
			&r.EffectiveTPS, &r.StaticTPS, &r.ProviderStatus, &r.ProviderTrustLevel, &r.ProviderVersion,
			&r.HardwareChip, &r.HardwareChipFamily, &r.HardwareTier, &r.MemoryGB, &r.GPUCores, &r.CPUCores,
			&r.SystemMemoryPressure, &r.SystemCPUUsage, &r.SystemThermalState,
			&r.GPUMemoryActiveGB, &r.GPUMemoryPeakGB, &r.GPUMemoryCacheGB,
			&r.SlotState, &r.BackendRunning, &r.BackendWaiting,
			&r.ActiveTokenBudgetUsed, &r.ActiveTokenBudgetMax, &r.QueuedTokenBudget,
			&r.EstimatedPromptTokens, &r.RequestedMaxTokens,
			&r.RequiresVision, &r.HasTools, &r.SelfRouteOnly, &r.PreferOwner,
			&finalStatus, &errorCode, &errorClass, &promptTokens, &completionTokens, &reasoningTokens, &costMicroUSD,
			&actualTTFTMs, &dispatchToFirstChunkMs, &totalDurationMs,
			&r.CreatedAt, &r.UpdatedAt,
			&providerRegion, &consumerRegion,
			&parseMs, &reserveMs, &routeMs, &encryptMs, &queueWaitMs, &dispatchMs, &actualDecodeTPS,
			&admittedButFailed, &usedBackup, &backupWon, &errorReason,
		); err != nil {
			continue
		}
		if providerRegion != nil {
			r.ProviderRegion = *providerRegion
		}
		if consumerRegion != nil {
			r.ConsumerRegion = *consumerRegion
		}
		outcome := contracts.InferenceRouteOutcome{FinalStatus: finalStatus}
		if errorCode != nil {
			outcome.ErrorCode = *errorCode
		}
		if errorClass != nil {
			outcome.ErrorClass = *errorClass
		}
		if errorReason != nil {
			outcome.ErrorReason = *errorReason
		}
		if promptTokens != nil {
			outcome.PromptTokens = *promptTokens
		}
		if completionTokens != nil {
			outcome.CompletionTokens = *completionTokens
		}
		if reasoningTokens != nil {
			outcome.ReasoningTokens = *reasoningTokens
		}
		if costMicroUSD != nil {
			outcome.CostMicroUSD = *costMicroUSD
		}
		if actualTTFTMs != nil {
			outcome.ActualTTFTMs = *actualTTFTMs
		}
		if dispatchToFirstChunkMs != nil {
			outcome.DispatchToFirstChunkMs = *dispatchToFirstChunkMs
		}
		if totalDurationMs != nil {
			outcome.TotalDurationMs = *totalDurationMs
		}
		if parseMs != nil {
			outcome.ParseMs = *parseMs
		}
		if reserveMs != nil {
			outcome.ReserveMs = *reserveMs
		}
		if routeMs != nil {
			outcome.RouteMs = *routeMs
		}
		if encryptMs != nil {
			outcome.EncryptMs = *encryptMs
		}
		if queueWaitMs != nil {
			outcome.QueueWaitMs = *queueWaitMs
		}
		if dispatchMs != nil {
			outcome.DispatchMs = *dispatchMs
		}
		if actualDecodeTPS != nil {
			outcome.ActualDecodeTPS = *actualDecodeTPS
		}
		if admittedButFailed != nil {
			outcome.AdmittedButFailed = *admittedButFailed
		}
		if usedBackup != nil {
			outcome.UsedBackup = *usedBackup
		}
		if backupWon != nil {
			outcome.BackupWon = *backupWon
		}
		routerecord.ApplyInferenceRouteOutcomeToRecord(&r, outcome)
		records = append(records, r)
	}
	return records
}
