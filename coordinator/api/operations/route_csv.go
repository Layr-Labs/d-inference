package operations

import (
	"encoding/csv"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// routeCSVHeader lists the route export columns in struct-field order.
var routeCSVHeader = []string{
	"request_id", "attempt", "provider_id", "model", "public_model",
	"consumer_key_hash", "key_id", "outcome",
	"cost_ms", "state_ms", "queue_ms", "pending_ms", "backlog_ms",
	"this_req_ms", "health_ms", "ttft_ms", "best_ttft_ms",
	"effective_queue", "candidate_count", "capacity_rejections",
	"model_too_large_rejections", "vision_rejections", "ttft_rejections",
	"effective_tps", "static_tps",
	"provider_status", "provider_trust_level", "provider_version",
	"hardware_chip", "hardware_chip_family", "hardware_tier",
	"memory_gb", "gpu_cores", "cpu_cores",
	"system_memory_pressure", "system_cpu_usage", "system_thermal_state",
	"gpu_memory_active_gb", "gpu_memory_peak_gb", "gpu_memory_cache_gb",
	"slot_state", "backend_running", "backend_waiting",
	"active_token_budget_used", "active_token_budget_max", "queued_token_budget",
	"estimated_prompt_tokens", "requested_max_tokens",
	"requires_vision", "has_tools", "self_route_only", "prefer_owner",
	"provider_region", "consumer_region",
	"final_status", "error_code", "error_class", "error_reason",
	"prompt_tokens", "completion_tokens", "reasoning_tokens", "cost_micro_usd",
	"actual_ttft_ms", "dispatch_to_first_chunk_ms", "total_duration_ms",
	"parse_ms", "reserve_ms", "route_ms", "encrypt_ms", "queue_wait_ms", "dispatch_ms",
	"actual_decode_tps", "admitted_but_failed", "used_backup", "backup_won",
	"created_at", "updated_at",
}

// writeRouteCSV streams a header row followed by one row per record to w, then
// flushes and reports any write error.
func writeRouteCSV(w http.ResponseWriter, records []store.InferenceRouteRecord) error {
	cw := csv.NewWriter(w)
	if err := cw.Write(routeCSVHeader); err != nil {
		return err
	}
	for i := range records {
		if err := cw.Write(guardCSVRow(routeCSVRow(records[i]))); err != nil {
			return err
		}
	}
	cw.Flush()
	return cw.Error()
}

// routeCSVRow flattens one record into CSV cells matching routeCSVHeader.
func routeCSVRow(rec store.InferenceRouteRecord) []string {
	return []string{
		rec.RequestID,
		csvInt(rec.Attempt),
		rec.ProviderID,
		rec.Model,
		rec.PublicModel,
		rec.ConsumerKeyHash,
		rec.KeyID,
		rec.Outcome,
		csvFloat(rec.CostMs),
		csvFloat(rec.StateMs),
		csvFloat(rec.QueueMs),
		csvFloat(rec.PendingMs),
		csvFloat(rec.BacklogMs),
		csvFloat(rec.ThisReqMs),
		csvFloat(rec.HealthMs),
		csvFloat(rec.TTFTMs),
		csvFloat(rec.BestTTFTMs),
		csvInt(rec.EffectiveQueue),
		csvInt(rec.CandidateCount),
		csvInt(rec.CapacityRejections),
		csvInt(rec.ModelTooLargeRejections),
		csvInt(rec.VisionRejections),
		csvInt(rec.TTFTRejections),
		csvFloat(rec.EffectiveTPS),
		csvFloat(rec.StaticTPS),
		rec.ProviderStatus,
		rec.ProviderTrustLevel,
		rec.ProviderVersion,
		rec.HardwareChip,
		rec.HardwareChipFamily,
		rec.HardwareTier,
		csvInt(rec.MemoryGB),
		csvInt(rec.GPUCores),
		csvInt(rec.CPUCores),
		csvFloat(rec.SystemMemoryPressure),
		csvFloat(rec.SystemCPUUsage),
		rec.SystemThermalState,
		csvFloat(rec.GPUMemoryActiveGB),
		csvFloat(rec.GPUMemoryPeakGB),
		csvFloat(rec.GPUMemoryCacheGB),
		rec.SlotState,
		csvInt(rec.BackendRunning),
		csvInt(rec.BackendWaiting),
		csvI64(rec.ActiveTokenBudgetUsed),
		csvI64(rec.ActiveTokenBudgetMax),
		csvI64(rec.QueuedTokenBudget),
		csvInt(rec.EstimatedPromptTokens),
		csvInt(rec.RequestedMaxTokens),
		csvBool(rec.RequiresVision),
		csvBool(rec.HasTools),
		csvBool(rec.SelfRouteOnly),
		csvBool(rec.PreferOwner),
		rec.ProviderRegion,
		rec.ConsumerRegion,
		rec.FinalStatus,
		csvInt(rec.ErrorCode),
		rec.ErrorClass,
		rec.ErrorReason,
		csvInt(rec.PromptTokens),
		csvInt(rec.CompletionTokens),
		csvInt(rec.ReasoningTokens),
		csvI64(rec.CostMicroUSD),
		csvFloat(rec.ActualTTFTMs),
		csvFloat(rec.DispatchToFirstChunkMs),
		csvFloat(rec.TotalDurationMs),
		csvFloat(rec.ParseMs),
		csvFloat(rec.ReserveMs),
		csvFloat(rec.RouteMs),
		csvFloat(rec.EncryptMs),
		csvFloat(rec.QueueWaitMs),
		csvFloat(rec.DispatchMs),
		csvFloat(rec.ActualDecodeTPS),
		csvBool(rec.AdmittedButFailed),
		csvBool(rec.UsedBackup),
		csvBool(rec.BackupWon),
		csvTime(rec.CreatedAt),
		csvTime(rec.UpdatedAt),
	}
}
