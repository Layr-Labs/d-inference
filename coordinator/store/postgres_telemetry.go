package store

import (
	"context"
	"encoding/json"
	"time"
)

// RecordInferenceRoute writes the routing decision snapshot for a request
// attempt. Best-effort; failures are discarded and never block inference.
func (s *PostgresStore) RecordInferenceRoute(record *InferenceRouteRecord) error {
	if record == nil {
		return nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	now := time.Now().UTC()
	createdAt := record.CreatedAt
	if createdAt.IsZero() {
		createdAt = now
	}
	updatedAt := record.UpdatedAt
	if updatedAt.IsZero() {
		updatedAt = now
	}

	_, _ = s.pool.Exec(ctx,
		`INSERT INTO inference_routes (
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
			requires_vision, has_tools, self_route_only, prefer_owner, cache_affinity_key,
			created_at, updated_at,
			provider_region, consumer_region
		) VALUES (
			$1, $2, $3, $4, $5, $6, $7, $8,
			$9, $10, $11, $12, $13, $14, $15, $16, $17,
			$18, $19, $20, $21, $22, $23,
			$24, $25, $26, $27, $28,
			$29, $30, $31, $32, $33, $34,
			$35, $36, $37,
			$38, $39, $40,
			$41, $42, $43,
			$44, $45, $46,
			$47, $48,
			$49, $50, $51, $52, $53,
			$54, $55,
			$56, $57
		) ON CONFLICT (request_id, attempt) DO NOTHING`,
		record.RequestID, record.Attempt, record.ProviderID, record.Model, record.PublicModel, record.ConsumerKeyHash, record.KeyID, record.Outcome,
		record.CostMs, record.StateMs, record.QueueMs, record.PendingMs, record.BacklogMs, record.ThisReqMs, record.HealthMs, record.TTFTMs, record.BestTTFTMs,
		record.EffectiveQueue, record.CandidateCount, record.CapacityRejections, record.ModelTooLargeRejections, record.VisionRejections, record.TTFTRejections,
		record.EffectiveTPS, record.StaticTPS, record.ProviderStatus, record.ProviderTrustLevel, record.ProviderVersion,
		record.HardwareChip, record.HardwareChipFamily, record.HardwareTier, record.MemoryGB, record.GPUCores, record.CPUCores,
		record.SystemMemoryPressure, record.SystemCPUUsage, record.SystemThermalState,
		record.GPUMemoryActiveGB, record.GPUMemoryPeakGB, record.GPUMemoryCacheGB,
		record.SlotState, record.BackendRunning, record.BackendWaiting,
		record.ActiveTokenBudgetUsed, record.ActiveTokenBudgetMax, record.QueuedTokenBudget,
		record.EstimatedPromptTokens, record.RequestedMaxTokens,
		record.RequiresVision, record.HasTools, record.SelfRouteOnly, record.PreferOwner, record.CacheAffinityKey,
		createdAt, updatedAt,
		record.ProviderRegion, record.ConsumerRegion,
	)
	return nil
}

// UpdateInferenceRouteOutcome updates the attempt with final outcome data
// (tokens, timing, error). Best-effort; failures are discarded.
func (s *PostgresStore) UpdateInferenceRouteOutcome(requestID string, attempt int, outcome *InferenceRouteOutcome) error {
	if outcome == nil {
		return nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, _ = s.pool.Exec(ctx,
		`UPDATE inference_routes SET
			final_status = $3,
			error_code = $4,
			error_class = $5,
			prompt_tokens = $6,
			completion_tokens = $7,
			reasoning_tokens = $8,
			cost_micro_usd = $9,
			actual_ttft_ms = $10,
			dispatch_to_first_chunk_ms = $11,
			total_duration_ms = $12,
			parse_ms = $13,
			reserve_ms = $14,
			route_ms = $15,
			encrypt_ms = $16,
			queue_wait_ms = $17,
			dispatch_ms = $18,
			actual_decode_tps = $19,
			admitted_but_failed = $20,
			used_backup = $21,
			backup_won = $22,
			updated_at = NOW()
		 WHERE request_id = $1 AND attempt = $2`,
		requestID, attempt,
		outcome.FinalStatus, outcome.ErrorCode, outcome.ErrorClass, outcome.PromptTokens, outcome.CompletionTokens, outcome.ReasoningTokens,
		outcome.CostMicroUSD, outcome.ActualTTFTMs, outcome.DispatchToFirstChunkMs, outcome.TotalDurationMs,
		outcome.ParseMs, outcome.ReserveMs, outcome.RouteMs, outcome.EncryptMs, outcome.QueueWaitMs, outcome.DispatchMs, outcome.ActualDecodeTPS,
		outcome.AdmittedButFailed, outcome.UsedBackup, outcome.BackupWon,
	)
	return nil
}

// InferenceRouteRecordsSince returns routing records created at or after the
// given time. Zero since returns all records.
func (s *PostgresStore) InferenceRouteRecordsSince(since time.Time) []InferenceRouteRecord {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT * FROM inference_routes WHERE created_at >= $1 ORDER BY created_at DESC LIMIT $2`,
		since, maxTelemetryReadRows)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var records []InferenceRouteRecord
	for rows.Next() {
		var r InferenceRouteRecord
		var id int64
		var finalStatus string
		var errorCode *int
		var errorClass *string
		var promptTokens *int
		var completionTokens *int
		var reasoningTokens *int
		var costMicroUSD *int64
		var actualTTFTMs *float64
		var dispatchToFirstChunkMs *float64
		var totalDurationMs *float64
		// Region fields are real record fields; the remaining outcome-gap
		// columns are scanned into throwaway locals (mirrors the existing
		// outcome columns above, which the record type does not carry).
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
			&r.RequiresVision, &r.HasTools, &r.SelfRouteOnly, &r.PreferOwner, &r.CacheAffinityKey,
			&finalStatus, &errorCode, &errorClass, &promptTokens, &completionTokens, &reasoningTokens, &costMicroUSD,
			&actualTTFTMs, &dispatchToFirstChunkMs, &totalDurationMs,
			&r.CreatedAt, &r.UpdatedAt,
			&providerRegion, &consumerRegion,
			&parseMs, &reserveMs, &routeMs, &encryptMs, &queueWaitMs, &dispatchMs, &actualDecodeTPS,
			&admittedButFailed, &usedBackup, &backupWon,
		); err != nil {
			continue
		}
		if providerRegion != nil {
			r.ProviderRegion = *providerRegion
		}
		if consumerRegion != nil {
			r.ConsumerRegion = *consumerRegion
		}
		records = append(records, r)
	}
	return records
}

// RecordRejection writes a rejected-request record with its counterfactual
// servability snapshot. Best-effort; failures are discarded and never block
// the request path.
func (s *PostgresStore) RecordRejection(record *RejectionRecord) error {
	if record == nil {
		return nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	createdAt := record.CreatedAt
	if createdAt.IsZero() {
		createdAt = time.Now().UTC()
	}

	// Mirror marshalProviderLocation's JSONB handling: pass nil (→ SQL NULL)
	// when there are no params so we never write an invalid empty JSONB value.
	var params json.RawMessage
	if len(record.Params) > 0 {
		params = record.Params
	}

	_, _ = s.pool.Exec(ctx,
		`INSERT INTO request_rejections (
			request_id, endpoint, stage, reason_code, http_status, consumer_key_hash, key_id, client_class,
			requested_model, resolved_model, stream, n, estimated_prompt_tokens, requested_max_tokens,
			requires_vision, has_image, has_audio, has_tools, tool_count, response_format, self_route_only, prefer_owner,
			params, request_body_bytes, retry_after_ms,
			could_have_served, candidate_count, capacity_rejections, model_too_large_rejections, vision_rejections,
			warm_provider_existed, best_ttft_ms, shortfall_micro_usd, limit_kind, over_by,
			created_at
		) VALUES (
			$1, $2, $3, $4, $5, $6, $7, $8,
			$9, $10, $11, $12, $13, $14,
			$15, $16, $17, $18, $19, $20, $21, $22,
			$23, $24, $25,
			$26, $27, $28, $29, $30,
			$31, $32, $33, $34, $35,
			$36
		)`,
		record.RequestID, record.Endpoint, record.Stage, record.ReasonCode, record.HTTPStatus, record.ConsumerKeyHash, record.KeyID, record.ClientClass,
		record.RequestedModel, record.ResolvedModel, record.Stream, record.N, record.EstimatedPromptTokens, record.RequestedMaxTokens,
		record.RequiresVision, record.HasImage, record.HasAudio, record.HasTools, record.ToolCount, record.ResponseFormat, record.SelfRouteOnly, record.PreferOwner,
		params, record.RequestBodyBytes, record.RetryAfterMs,
		record.CouldHaveServed, record.CandidateCount, record.CapacityRejections, record.ModelTooLargeRejections, record.VisionRejections,
		record.WarmProviderExisted, record.BestTTFTMs, record.ShortfallMicroUSD, record.LimitKind, record.OverBy,
		createdAt,
	)
	return nil
}

// RejectionRecordsSince returns rejection records created at or after the given
// time. Zero since returns all records.
func (s *PostgresStore) RejectionRecordsSince(since time.Time) []RejectionRecord {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT * FROM request_rejections WHERE created_at >= $1 ORDER BY created_at DESC LIMIT $2`,
		since, maxTelemetryReadRows)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var records []RejectionRecord
	for rows.Next() {
		var r RejectionRecord
		var id int64
		var paramsRaw []byte

		if err := rows.Scan(
			&id,
			&r.RequestID, &r.Endpoint, &r.Stage, &r.ReasonCode, &r.HTTPStatus, &r.ConsumerKeyHash, &r.KeyID, &r.ClientClass,
			&r.RequestedModel, &r.ResolvedModel, &r.Stream, &r.N, &r.EstimatedPromptTokens, &r.RequestedMaxTokens,
			&r.RequiresVision, &r.HasImage, &r.HasAudio, &r.HasTools, &r.ToolCount, &r.ResponseFormat, &r.SelfRouteOnly, &r.PreferOwner,
			&paramsRaw, &r.RequestBodyBytes, &r.RetryAfterMs,
			&r.CouldHaveServed, &r.CandidateCount, &r.CapacityRejections, &r.ModelTooLargeRejections, &r.VisionRejections,
			&r.WarmProviderExisted, &r.BestTTFTMs, &r.ShortfallMicroUSD, &r.LimitKind, &r.OverBy,
			&r.CreatedAt,
		); err != nil {
			continue
		}
		if len(paramsRaw) > 0 {
			r.Params = paramsRaw
		}
		records = append(records, r)
	}
	return records
}
