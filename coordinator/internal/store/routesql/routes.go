package routesql

import (
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/store/shared"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const ErrorReasonUpsertAssignment = "error_reason = COALESCE(NULLIF(EXCLUDED.error_reason, ''), inference_routes.error_reason)"

// inferenceRouteInsertColumns is the ordered insert column list.
// inferenceRouteInsertArgs MUST append values in exactly this order.
const InsertColumns = `request_id, attempt, provider_id, model, public_model, consumer_key_hash, key_id, outcome,
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
			created_at, updated_at,
			provider_region, consumer_region, error_reason`

// inferenceRouteInsertParamCount is the number of bind parameters per row —
// the length of inferenceRouteInsertColumns.
const InsertParamCount = 57

// maxInferenceRouteInsertRows caps the rows in one multi-row INSERT so the
// statement stays far below PostgreSQL's 65535 bind-parameter ceiling
// (57 x 512 = 29184). Larger batches are written as several statements.
const MaxInsertRows = 512

// inferenceRouteUpsertAssignments is the ON CONFLICT (request_id, attempt) DO
// UPDATE block. It refreshes the routing snapshot columns only: the outcome
// columns written by UpdateInferenceRouteOutcome are deliberately untouched
// (error_reason keeps the existing value unless the record carries one), and
// created_at keeps the first insert's timestamp.
const UpsertAssignments = `provider_id = EXCLUDED.provider_id,
			model = EXCLUDED.model,
			public_model = EXCLUDED.public_model,
			consumer_key_hash = EXCLUDED.consumer_key_hash,
			key_id = EXCLUDED.key_id,
			outcome = EXCLUDED.outcome,
			cost_ms = EXCLUDED.cost_ms,
			state_ms = EXCLUDED.state_ms,
			queue_ms = EXCLUDED.queue_ms,
			pending_ms = EXCLUDED.pending_ms,
			backlog_ms = EXCLUDED.backlog_ms,
			this_req_ms = EXCLUDED.this_req_ms,
			health_ms = EXCLUDED.health_ms,
			ttft_ms = EXCLUDED.ttft_ms,
			best_ttft_ms = EXCLUDED.best_ttft_ms,
			effective_queue = EXCLUDED.effective_queue,
			candidate_count = EXCLUDED.candidate_count,
			capacity_rejections = EXCLUDED.capacity_rejections,
			model_too_large_rejections = EXCLUDED.model_too_large_rejections,
			vision_rejections = EXCLUDED.vision_rejections,
			ttft_rejections = EXCLUDED.ttft_rejections,
			effective_tps = EXCLUDED.effective_tps,
			static_tps = EXCLUDED.static_tps,
			provider_status = EXCLUDED.provider_status,
			provider_trust_level = EXCLUDED.provider_trust_level,
			provider_version = EXCLUDED.provider_version,
			hardware_chip = EXCLUDED.hardware_chip,
			hardware_chip_family = EXCLUDED.hardware_chip_family,
			hardware_tier = EXCLUDED.hardware_tier,
			memory_gb = EXCLUDED.memory_gb,
			gpu_cores = EXCLUDED.gpu_cores,
			cpu_cores = EXCLUDED.cpu_cores,
			system_memory_pressure = EXCLUDED.system_memory_pressure,
			system_cpu_usage = EXCLUDED.system_cpu_usage,
			system_thermal_state = EXCLUDED.system_thermal_state,
			gpu_memory_active_gb = EXCLUDED.gpu_memory_active_gb,
			gpu_memory_peak_gb = EXCLUDED.gpu_memory_peak_gb,
			gpu_memory_cache_gb = EXCLUDED.gpu_memory_cache_gb,
			slot_state = EXCLUDED.slot_state,
			backend_running = EXCLUDED.backend_running,
			backend_waiting = EXCLUDED.backend_waiting,
			active_token_budget_used = EXCLUDED.active_token_budget_used,
			active_token_budget_max = EXCLUDED.active_token_budget_max,
			queued_token_budget = EXCLUDED.queued_token_budget,
			estimated_prompt_tokens = EXCLUDED.estimated_prompt_tokens,
			requested_max_tokens = EXCLUDED.requested_max_tokens,
			requires_vision = EXCLUDED.requires_vision,
			has_tools = EXCLUDED.has_tools,
			self_route_only = EXCLUDED.self_route_only,
			prefer_owner = EXCLUDED.prefer_owner,
			provider_region = EXCLUDED.provider_region,
			consumer_region = EXCLUDED.consumer_region,
			` + ErrorReasonUpsertAssignment + `,
			updated_at = EXCLUDED.updated_at`

// inferenceRouteOutcomeUpdateSQL merges one outcome onto its route row with
// "zero means not present" semantics (mirrors mergeInferenceRouteOutcome).
// $24 (CompletionTokensSet) force-writes completion_tokens even when 0 so a
// terminal cancel/error/timeout row persists 0 instead of NULL.
const OutcomeUpdateSQL = `UPDATE inference_routes SET
			final_status = COALESCE(NULLIF($3, ''), final_status),
			error_code = CASE WHEN $4 <> 0 THEN $4 ELSE error_code END,
			error_class = COALESCE(NULLIF($5, ''), error_class),
			error_reason = COALESCE(NULLIF($6, ''), error_reason),
			prompt_tokens = CASE WHEN $7 <> 0 THEN $7 ELSE prompt_tokens END,
			completion_tokens = CASE WHEN $24 OR $8 <> 0 THEN $8 ELSE completion_tokens END,
			reasoning_tokens = CASE WHEN $9 <> 0 THEN $9 ELSE reasoning_tokens END,
			cost_micro_usd = CASE WHEN $10 <> 0 THEN $10 ELSE cost_micro_usd END,
			actual_ttft_ms = CASE WHEN $11 <> 0 THEN $11 ELSE actual_ttft_ms END,
			dispatch_to_first_chunk_ms = CASE WHEN $12 <> 0 THEN $12 ELSE dispatch_to_first_chunk_ms END,
			total_duration_ms = CASE WHEN $13 <> 0 THEN $13 ELSE total_duration_ms END,
			parse_ms = CASE WHEN $14 <> 0 THEN $14 ELSE parse_ms END,
			reserve_ms = CASE WHEN $15 <> 0 THEN $15 ELSE reserve_ms END,
			route_ms = CASE WHEN $16 <> 0 THEN $16 ELSE route_ms END,
			encrypt_ms = CASE WHEN $17 <> 0 THEN $17 ELSE encrypt_ms END,
			queue_wait_ms = CASE WHEN $18 <> 0 THEN $18 ELSE queue_wait_ms END,
			dispatch_ms = CASE WHEN $19 <> 0 THEN $19 ELSE dispatch_ms END,
			actual_decode_tps = CASE WHEN $20 <> 0 THEN $20 ELSE actual_decode_tps END,
			admitted_but_failed = COALESCE(admitted_but_failed, FALSE) OR $21,
			used_backup = COALESCE(used_backup, FALSE) OR $22,
			backup_won = COALESCE(backup_won, FALSE) OR $23,
			updated_at = NOW()
		 WHERE request_id = $1 AND attempt = $2`

// inferenceRouteInsertSQL builds the multi-row upsert for rows records:
// INSERT ... VALUES ($1..$57), ($58..$114), ... ON CONFLICT ... DO UPDATE.
// rows == 1 is byte-for-byte the historical single-row statement shape.
func InsertSQL(rows int) string {
	var b strings.Builder
	b.Grow(len(InsertColumns) + len(UpsertAssignments) + rows*InsertParamCount*6 + 128)
	b.WriteString("INSERT INTO inference_routes (\n\t\t\t")
	b.WriteString(InsertColumns)
	b.WriteString("\n\t\t) VALUES ")
	param := 1
	for r := 0; r < rows; r++ {
		if r > 0 {
			b.WriteString(",\n\t\t")
		}
		b.WriteByte('(')
		for c := 0; c < InsertParamCount; c++ {
			if c > 0 {
				b.WriteString(", ")
			}
			b.WriteByte('$')
			b.WriteString(strconv.Itoa(param))
			param++
		}
		b.WriteByte(')')
	}
	b.WriteString(" ON CONFLICT (request_id, attempt) DO UPDATE SET\n\t\t\t")
	b.WriteString(UpsertAssignments)
	return b.String()
}

// inferenceRouteInsertArgs appends record's bind values to dst in
// inferenceRouteInsertColumns order. Zero CreatedAt/UpdatedAt default to now.
func InsertArgs(dst []any, record *store.InferenceRouteRecord, now time.Time) []any {
	createdAt := record.CreatedAt
	if createdAt.IsZero() {
		createdAt = now
	}
	updatedAt := record.UpdatedAt
	if updatedAt.IsZero() {
		updatedAt = now
	}
	return append(dst,
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
		record.RequiresVision, record.HasTools, record.SelfRouteOnly, record.PreferOwner,
		createdAt, updatedAt,
		record.ProviderRegion, record.ConsumerRegion, record.ErrorReason,
	)
}

// inferenceRouteOutcomeUpdateArgs returns the bind values for
// inferenceRouteOutcomeUpdateSQL.
func OutcomeUpdateArgs(requestID string, attempt int, outcome *store.InferenceRouteOutcome) []any {
	return []any{
		requestID, attempt,
		outcome.FinalStatus, outcome.ErrorCode, outcome.ErrorClass, outcome.ErrorReason, outcome.PromptTokens, outcome.CompletionTokens, outcome.ReasoningTokens,
		outcome.CostMicroUSD, outcome.ActualTTFTMs, outcome.DispatchToFirstChunkMs, outcome.TotalDurationMs,
		outcome.ParseMs, outcome.ReserveMs, outcome.RouteMs, outcome.EncryptMs, outcome.QueueWaitMs, outcome.DispatchMs, outcome.ActualDecodeTPS,
		outcome.AdmittedButFailed, outcome.UsedBackup, outcome.BackupWon,
		outcome.CompletionTokensSet,
	}
}

// splitInferenceRouteBatches partitions records, preserving order, into
// slices that are safe to write as ONE multi-row upsert each:
//
//   - a slice never contains the same (request_id, attempt) twice, because a
//     single INSERT ... ON CONFLICT DO UPDATE cannot affect one row a second
//     time — the duplicate starts the next slice, so the later record refreshes
//     the earlier one exactly as sequential single-row calls would;
//   - a slice holds at most maxRows records (bind-parameter budget).
//
// Nil records are dropped. maxRows <= 0 means unbounded.
func SplitBatches(records []*store.InferenceRouteRecord, maxRows int) [][]*store.InferenceRouteRecord {
	var out [][]*store.InferenceRouteRecord
	var cur []*store.InferenceRouteRecord
	seen := map[string]struct{}{}
	flush := func() {
		if len(cur) > 0 {
			out = append(out, cur)
			cur = nil
			seen = map[string]struct{}{}
		}
	}
	for _, r := range records {
		if r == nil {
			continue
		}
		key := shared.InferenceRouteKey(r.RequestID, r.Attempt)
		if _, dup := seen[key]; dup || (maxRows > 0 && len(cur) >= maxRows) {
			flush()
		}
		seen[key] = struct{}{}
		cur = append(cur, r)
	}
	flush()
	return out
}
