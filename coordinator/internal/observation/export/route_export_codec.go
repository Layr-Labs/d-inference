package export

import (
	"encoding/csv"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// filterRouteRecords applies the optional in-memory filters supported by the
// routes endpoints. Empty filter values are ignored. model matches either the
// concrete Model or the consumer-facing PublicModel.
func FilterRoutes(in []store.InferenceRouteRecord, provider, model, outcome, finalStatus string) []store.InferenceRouteRecord {
	if provider == "" && model == "" && outcome == "" && finalStatus == "" {
		return in
	}
	out := make([]store.InferenceRouteRecord, 0, len(in))
	for _, rec := range in {
		if provider != "" && rec.ProviderID != provider {
			continue
		}
		if model != "" && rec.Model != model && rec.PublicModel != model {
			continue
		}
		if outcome != "" && rec.Outcome != outcome {
			continue
		}
		if finalStatus != "" && rec.FinalStatus != finalStatus {
			continue
		}
		out = append(out, rec)
	}
	return out
}

// filterRejectionRecords applies the optional in-memory filters supported by the
// rejections endpoints. Empty filter values are ignored. model matches either
// RequestedModel or ResolvedModel; couldHaveServed filters on the boolean only
// when it is exactly "true" or "false".
func FilterRejections(in []store.RejectionRecord, reason, model, couldHaveServed string) []store.RejectionRecord {
	var wantServed *bool
	switch strings.ToLower(strings.TrimSpace(couldHaveServed)) {
	case "true":
		v := true
		wantServed = &v
	case "false":
		v := false
		wantServed = &v
	}
	if reason == "" && model == "" && wantServed == nil {
		return in
	}
	out := make([]store.RejectionRecord, 0, len(in))
	for _, rec := range in {
		if reason != "" && rec.ReasonCode != reason {
			continue
		}
		if model != "" && rec.RequestedModel != model && rec.ResolvedModel != model {
			continue
		}
		if wantServed != nil && (rec.CouldHaveServed == nil || *rec.CouldHaveServed != *wantServed) {
			continue
		}
		out = append(out, rec)
	}
	return out
}

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
func RouteCSVHeader() []string { return append([]string(nil), routeCSVHeader...) }

func WriteRouteCSV(w http.ResponseWriter, records []store.InferenceRouteRecord) error {
	cw := csv.NewWriter(w)
	if err := cw.Write(RouteCSVHeader()); err != nil {
		return err
	}
	for i := range records {
		if err := cw.Write(guardCSVRow(RouteCSVRow(records[i]))); err != nil {
			return err
		}
	}
	cw.Flush()
	return cw.Error()
}

// routeCSVRow flattens one record into CSV cells matching routeCSVHeader.
func RouteCSVRow(rec store.InferenceRouteRecord) []string {
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

// rejectionCSVHeader lists the rejection export columns in struct-field order.
var rejectionCSVHeader = []string{
	"request_id", "endpoint", "stage", "reason_code", "http_status",
	"consumer_key_hash", "key_id", "client_class",
	"requested_model", "resolved_model", "stream", "n",
	"estimated_prompt_tokens", "requested_max_tokens",
	"requires_vision", "has_image", "has_audio", "has_tools", "tool_count",
	"response_format", "self_route_only", "prefer_owner", "params",
	"request_body_bytes", "retry_after_ms",
	"could_have_served", "candidate_count", "capacity_rejections",
	"model_too_large_rejections", "vision_rejections", "warm_provider_existed",
	"best_ttft_ms", "shortfall_micro_usd", "limit_kind", "over_by",
	"created_at",
}

// writeRejectionCSV streams a header row followed by one row per record to w,
// then flushes and reports any write error.
func WriteRejectionCSV(w http.ResponseWriter, records []store.RejectionRecord) error {
	cw := csv.NewWriter(w)
	if err := cw.Write(rejectionCSVHeader); err != nil {
		return err
	}
	for i := range records {
		if err := cw.Write(guardCSVRow(rejectionCSVRow(records[i]))); err != nil {
			return err
		}
	}
	cw.Flush()
	return cw.Error()
}

// rejectionCSVRow flattens one record into CSV cells matching
// rejectionCSVHeader. The json.RawMessage Params field is emitted as a string.
func rejectionCSVRow(rec store.RejectionRecord) []string {
	return []string{
		rec.RequestID,
		rec.Endpoint,
		rec.Stage,
		rec.ReasonCode,
		csvInt(rec.HTTPStatus),
		rec.ConsumerKeyHash,
		rec.KeyID,
		rec.ClientClass,
		rec.RequestedModel,
		rec.ResolvedModel,
		csvBool(rec.Stream),
		csvInt(rec.N),
		csvInt(rec.EstimatedPromptTokens),
		csvInt(rec.RequestedMaxTokens),
		csvBool(rec.RequiresVision),
		csvBool(rec.HasImage),
		csvBool(rec.HasAudio),
		csvBool(rec.HasTools),
		csvInt(rec.ToolCount),
		rec.ResponseFormat,
		csvBool(rec.SelfRouteOnly),
		csvBool(rec.PreferOwner),
		string(rec.Params),
		csvInt(rec.RequestBodyBytes),
		csvInt(rec.RetryAfterMs),
		csvOptionalBool(rec.CouldHaveServed),
		csvInt(rec.CandidateCount),
		csvInt(rec.CapacityRejections),
		csvInt(rec.ModelTooLargeRejections),
		csvInt(rec.VisionRejections),
		csvBool(rec.WarmProviderExisted),
		csvFloat(rec.BestTTFTMs),
		csvI64(rec.ShortfallMicroUSD),
		rec.LimitKind,
		csvI64(rec.OverBy),
		csvTime(rec.CreatedAt),
	}
}

func csvInt(v int) string { return strconv.Itoa(v) }

func csvI64(v int64) string { return strconv.FormatInt(v, 10) }

func csvFloat(v float64) string { return strconv.FormatFloat(v, 'f', -1, 64) }

func csvBool(v bool) string { return strconv.FormatBool(v) }

func csvTime(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.Format(time.RFC3339)
}

// An empty CSV cell, like JSON null and SQL NULL, denotes unknown servability.
func csvOptionalBool(value *bool) string {
	if value == nil {
		return ""
	}
	return csvBool(*value)
}
