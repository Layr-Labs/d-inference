package store

import (
	"context"
	"fmt"
	"time"
)

const inferenceRouteCandidateColumns = `
			request_id, attempt, provider_id, rank, selected, eligible, rejection_reason,
			cost_ms, state_ms, queue_ms, pending_ms, backlog_ms, this_req_ms, health_ms,
			capacity_rate_ms, ttft_ms, effective_queue, effective_tps, static_tps,
			effective_prefill_tps, static_prefill_tps, batch_size,
			chip_family, hardware_tier, memory_gb, slot_state, memory_pressure, thermal_state,
			gpu_memory_active_gb, free_for_load_gb, wedge_suspected, affinity_applied,
			affinity_discount_ms, capacity_reject_rate, created_at`

func (s *PostgresStore) RecordInferenceRouteCandidates(records []InferenceRouteCandidateRecord) error {
	if s == nil || s.pool == nil || len(records) == 0 {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	now := time.Now().UTC()
	for i := range records {
		rec := records[i]
		if rec.RequestID == "" || rec.ProviderID == "" {
			continue
		}
		createdAt := rec.CreatedAt
		if createdAt.IsZero() {
			createdAt = now
		}
		if _, err := s.pool.Exec(ctx,
			`INSERT INTO inference_route_candidates (
				request_id, attempt, provider_id, rank, selected, eligible, rejection_reason,
				cost_ms, state_ms, queue_ms, pending_ms, backlog_ms, this_req_ms, health_ms,
				capacity_rate_ms, ttft_ms, effective_queue, effective_tps, static_tps,
				effective_prefill_tps, static_prefill_tps, batch_size,
				chip_family, hardware_tier, memory_gb, slot_state, memory_pressure, thermal_state,
				gpu_memory_active_gb, free_for_load_gb, wedge_suspected, affinity_applied,
				affinity_discount_ms, capacity_reject_rate, created_at
			) VALUES (
				$1, $2, $3, $4, $5, $6, $7,
				$8, $9, $10, $11, $12, $13, $14,
				$15, $16, $17, $18, $19,
				$20, $21, $22,
				$23, $24, $25, $26, $27, $28,
				$29, $30, $31, $32,
				$33, $34, $35
			) ON CONFLICT (request_id, attempt, provider_id) DO UPDATE SET
				rank = EXCLUDED.rank,
				selected = EXCLUDED.selected,
				eligible = EXCLUDED.eligible,
				rejection_reason = EXCLUDED.rejection_reason,
				cost_ms = EXCLUDED.cost_ms,
				state_ms = EXCLUDED.state_ms,
				queue_ms = EXCLUDED.queue_ms,
				pending_ms = EXCLUDED.pending_ms,
				backlog_ms = EXCLUDED.backlog_ms,
				this_req_ms = EXCLUDED.this_req_ms,
				health_ms = EXCLUDED.health_ms,
				capacity_rate_ms = EXCLUDED.capacity_rate_ms,
				ttft_ms = EXCLUDED.ttft_ms,
				effective_queue = EXCLUDED.effective_queue,
				effective_tps = EXCLUDED.effective_tps,
				static_tps = EXCLUDED.static_tps,
				effective_prefill_tps = EXCLUDED.effective_prefill_tps,
				static_prefill_tps = EXCLUDED.static_prefill_tps,
				batch_size = EXCLUDED.batch_size,
				chip_family = EXCLUDED.chip_family,
				hardware_tier = EXCLUDED.hardware_tier,
				memory_gb = EXCLUDED.memory_gb,
				slot_state = EXCLUDED.slot_state,
				memory_pressure = EXCLUDED.memory_pressure,
				thermal_state = EXCLUDED.thermal_state,
				gpu_memory_active_gb = EXCLUDED.gpu_memory_active_gb,
				free_for_load_gb = EXCLUDED.free_for_load_gb,
				wedge_suspected = EXCLUDED.wedge_suspected,
				affinity_applied = EXCLUDED.affinity_applied,
				affinity_discount_ms = EXCLUDED.affinity_discount_ms,
				capacity_reject_rate = EXCLUDED.capacity_reject_rate`,
			rec.RequestID, rec.Attempt, rec.ProviderID, rec.Rank, rec.Selected, rec.Eligible, rec.RejectionReason,
			rec.CostMs, rec.StateMs, rec.QueueMs, rec.PendingMs, rec.BacklogMs, rec.ThisReqMs, rec.HealthMs,
			rec.CapacityRateMs, rec.TTFTMs, rec.EffectiveQueue, rec.EffectiveTPS, rec.StaticTPS,
			rec.EffectivePrefillTPS, rec.StaticPrefillTPS, rec.BatchSize,
			rec.ChipFamily, rec.HardwareTier, rec.MemoryGB, rec.SlotState, rec.MemoryPressure, rec.ThermalState,
			rec.GPUMemoryActiveGB, rec.FreeForLoadGB, rec.WedgeSuspected, rec.AffinityApplied,
			rec.AffinityDiscountMs, rec.CapacityRejectRate, createdAt,
		); err != nil {
			return fmt.Errorf("store: record inference route candidates: %w", err)
		}
	}
	return nil
}

func (s *PostgresStore) InferenceRouteCandidatesSince(since time.Time) []InferenceRouteCandidateRecord {
	if s == nil || s.pool == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	rows, err := s.pool.Query(ctx,
		`SELECT `+inferenceRouteCandidateColumns+` FROM inference_route_candidates
		 WHERE created_at >= $1 ORDER BY created_at DESC LIMIT $2`,
		since, maxTelemetryReadRows)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var records []InferenceRouteCandidateRecord
	for rows.Next() {
		var r InferenceRouteCandidateRecord
		if err := rows.Scan(
			&r.RequestID, &r.Attempt, &r.ProviderID, &r.Rank, &r.Selected, &r.Eligible, &r.RejectionReason,
			&r.CostMs, &r.StateMs, &r.QueueMs, &r.PendingMs, &r.BacklogMs, &r.ThisReqMs, &r.HealthMs,
			&r.CapacityRateMs, &r.TTFTMs, &r.EffectiveQueue, &r.EffectiveTPS, &r.StaticTPS,
			&r.EffectivePrefillTPS, &r.StaticPrefillTPS, &r.BatchSize,
			&r.ChipFamily, &r.HardwareTier, &r.MemoryGB, &r.SlotState, &r.MemoryPressure, &r.ThermalState,
			&r.GPUMemoryActiveGB, &r.FreeForLoadGB, &r.WedgeSuspected, &r.AffinityApplied,
			&r.AffinityDiscountMs, &r.CapacityRejectRate, &r.CreatedAt,
		); err != nil {
			continue
		}
		records = append(records, r)
	}
	return records
}

func (s *PostgresStore) RecordProviderCapacitySample(record *ProviderCapacitySample) error {
	if s == nil || s.pool == nil || record == nil || record.ProviderID == "" {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	createdAt := record.CreatedAt
	if createdAt.IsZero() {
		createdAt = time.Now().UTC()
	}
	if _, err := s.pool.Exec(ctx,
		`INSERT INTO provider_capacity_samples (
			provider_id, provider_version, provider_status, provider_trust_level,
			hardware_chip_family, hardware_tier, memory_gb, current_model,
			warm_model_count, slot_count, backend_running, backend_waiting,
			observed_decode_tps, active_token_budget_used, active_token_budget_max,
			queued_token_budget, memory_pressure, cpu_usage, thermal_state,
			gpu_memory_active_gb, gpu_memory_peak_gb, gpu_memory_cache_gb,
			free_for_load_gb, wedge_suspected, created_at
		) VALUES (
			$1, $2, $3, $4,
			$5, $6, $7, $8,
			$9, $10, $11, $12,
			$13, $14, $15,
			$16, $17, $18, $19,
			$20, $21, $22,
			$23, $24, $25
		)`,
		record.ProviderID, record.ProviderVersion, record.ProviderStatus, record.ProviderTrustLevel,
		record.HardwareChipFamily, record.HardwareTier, record.MemoryGB, record.CurrentModel,
		record.WarmModelCount, record.SlotCount, record.BackendRunning, record.BackendWaiting,
		record.ObservedDecodeTPS, record.ActiveTokenUsed, record.ActiveTokenMax,
		record.QueuedTokenBudget, record.MemoryPressure, record.CPUUsage, record.ThermalState,
		record.GPUMemoryActiveGB, record.GPUMemoryPeakGB, record.GPUMemoryCacheGB,
		record.FreeForLoadGB, record.WedgeSuspected, createdAt,
	); err != nil {
		return fmt.Errorf("store: record provider capacity sample: %w", err)
	}
	return nil
}

func (s *PostgresStore) ProviderCapacitySamplesSince(since time.Time) []ProviderCapacitySample {
	if s == nil || s.pool == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	rows, err := s.pool.Query(ctx,
		`SELECT
			provider_id, provider_version, provider_status, provider_trust_level,
			hardware_chip_family, hardware_tier, memory_gb, current_model,
			warm_model_count, slot_count, backend_running, backend_waiting,
			observed_decode_tps, active_token_budget_used, active_token_budget_max,
			queued_token_budget, memory_pressure, cpu_usage, thermal_state,
			gpu_memory_active_gb, gpu_memory_peak_gb, gpu_memory_cache_gb,
			free_for_load_gb, wedge_suspected, created_at
		 FROM provider_capacity_samples
		 WHERE created_at >= $1 ORDER BY created_at DESC LIMIT $2`,
		since, maxTelemetryReadRows)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var records []ProviderCapacitySample
	for rows.Next() {
		var r ProviderCapacitySample
		if err := rows.Scan(
			&r.ProviderID, &r.ProviderVersion, &r.ProviderStatus, &r.ProviderTrustLevel,
			&r.HardwareChipFamily, &r.HardwareTier, &r.MemoryGB, &r.CurrentModel,
			&r.WarmModelCount, &r.SlotCount, &r.BackendRunning, &r.BackendWaiting,
			&r.ObservedDecodeTPS, &r.ActiveTokenUsed, &r.ActiveTokenMax,
			&r.QueuedTokenBudget, &r.MemoryPressure, &r.CPUUsage, &r.ThermalState,
			&r.GPUMemoryActiveGB, &r.GPUMemoryPeakGB, &r.GPUMemoryCacheGB,
			&r.FreeForLoadGB, &r.WedgeSuspected, &r.CreatedAt,
		); err != nil {
			continue
		}
		records = append(records, r)
	}
	return records
}
