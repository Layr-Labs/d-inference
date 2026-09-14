package postgres

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/recordutil"
)

// requestProfileColumns is the request_profiles column list (without the
// BIGSERIAL id) in the one order shared by the INSERT, the SELECT and the scan.
// requestProfileValues and requestProfileScanTargets MUST stay in this order;
// TestRequestProfileColumnsStayAligned pins the three together.
var requestProfileColumns = []string{
	"coord_request_id", "request_id", "attempt", "backup_of", "winning", "endpoint", "stream",
	"model", "public_model", "provider_id", "provider_version", "chip_family", "kv_backend",
	"final_status", "error_reason", "terminal_cause", "client_outcome", "provider_outcome", "client_gone_phase",
	"first_content_budget_ms", "admission_mode", "predictive_bypass", "reservation_ttft_ceiling_ms", "dispatch_budget_ms",
	"estimated_prompt_tokens", "requested_max_tokens", "requires_vision", "has_tools", "received_at",

	"auth_done_us", "ratelimit_done_us", "sealed_open_us", "handler_entry_us", "parsed_us", "reserved_us", "media_fetched_us",
	"preflight_done_us", "plan_done_us", "attempt_start_us", "reserve_lock_acquired_us", "reserve_done_us", "queued_us", "dequeued_us",
	"topup_done_us", "encrypted_us", "write_submitted_us", "write_dequeued_us", "write_done_us", "accepted_us",
	"first_chunk_ingress_us", "first_chunk_dequeued_us", "first_content_ingress_us", "first_content_us", "headers_written_us",
	"first_flush_us", "last_flush_us", "client_gone_us", "cancel_sent_us", "complete_ingress_us", "done_flushed_us", "finalized_us",
	"settle_db_us", "db_us", "db_calls",

	"body_bytes", "sealed_body_bytes", "auth_kind", "auth_db_read", "reserve_mode", "media_items", "media_bytes",
	"preflight_outcome", "plan_outcome", "chunks_in", "chunks_out", "bytes_out", "decrypt_us_total", "max_chunk_gap_us",
	"held_preamble_chunks", "client_write_err", "attempts_total", "failed_attempts", "failed_attempts_us",
	"backup_launched", "backup_won", "transport_est_us", "slept_us", "timing_anomaly",

	"candidate_set_size", "scanned", "gate_rejections", "runner_up_provider_id", "runner_up_cost_ms", "near_tie_pool_size",
	"selection_path", "best_idle_provider_id", "best_idle_ttft_ms", "predicted_ttft_ms", "raw_ttft_ms", "predicted_decode_tps",
	"snapshot_age_ms", "pending_for_model", "total_pending", "capacity_rate_ms", "cache_discount_ms",
	"shadow_would_shed", "shadow_idle_alternative", "lock_wait_us", "scan_us", "admit_us", "preflight_us",
	"ttft_calibration_ratio", "prefill_decode_ratio", "queue_position_at_enqueue", "queue_depth_at_enqueue", "drain_trigger",
	"candidates",

	"prov_total_us", "prov_first_delta_us", "prov_engine_submit_us", "prov_engine_admitted_us", "prov_prompt_prep_us", "prov_load_wait_us",
	"prov_load_cold", "prov_running_at_admit", "prov_waiting_at_admit", "prov_kv_bytes_in_use_at_admit", "prov_cancel_stage",
	"eng_queue_wait_ns", "eng_first_token_ns", "eng_prompt_computed_ns", "eng_prefill_chunks", "eng_decode_steps", "eng_mtp_accepted",
	"eng_finish_reason", "provider_profile", "provider_profile_valid", "provider_profile_invalid_reason", "provider_profile_consistent",

	"created_at",
}

// requestProfileValues returns the INSERT parameters for r in
// requestProfileColumns order. createdAt is the resolved created_at value.
func requestProfileValues(r *contracts.RequestProfileRecord, createdAt time.Time) []any {
	return []any{
		r.CoordRequestID, r.RequestID, r.Attempt, r.BackupOf, r.Winning, r.Endpoint, r.Stream,
		r.Model, r.PublicModel, r.ProviderID, r.ProviderVersion, r.ChipFamily, r.KVBackend,
		r.FinalStatus, r.ErrorReason, r.TerminalCause, r.ClientOutcome, r.ProviderOutcome, r.ClientGonePhase,
		r.FirstContentBudgetMs, r.AdmissionMode, r.PredictiveBypass, r.ReservationTTFTCeilingMs, r.DispatchBudgetMs,
		r.EstimatedPromptTokens, r.RequestedMaxTokens, r.RequiresVision, r.HasTools, r.ReceivedAt,

		r.AuthDoneUS, r.RatelimitDoneUS, r.SealedOpenUS, r.HandlerEntryUS, r.ParsedUS, r.ReservedUS, r.MediaFetchedUS,
		r.PreflightDoneUS, r.PlanDoneUS, r.AttemptStartUS, r.ReserveLockAcquiredUS, r.ReserveDoneUS, r.QueuedUS, r.DequeuedUS,
		r.TopupDoneUS, r.EncryptedUS, r.WriteSubmittedUS, r.WriteDequeuedUS, r.WriteDoneUS, r.AcceptedUS,
		r.FirstChunkIngressUS, r.FirstChunkDequeuedUS, r.FirstContentIngressUS, r.FirstContentUS, r.HeadersWrittenUS,
		r.FirstFlushUS, r.LastFlushUS, r.ClientGoneUS, r.CancelSentUS, r.CompleteIngressUS, r.DoneFlushedUS, r.FinalizedUS,
		r.SettleDBUS, r.DBUS, r.DBCalls,

		r.BodyBytes, r.SealedBodyBytes, r.AuthKind, r.AuthDBRead, r.ReserveMode, r.MediaItems, r.MediaBytes,
		r.PreflightOutcome, r.PlanOutcome, r.ChunksIn, r.ChunksOut, r.BytesOut, r.DecryptUSTotal, r.MaxChunkGapUS,
		r.HeldPreambleChunks, r.ClientWriteErr, r.AttemptsTotal, r.FailedAttempts, r.FailedAttemptsUS,
		r.BackupLaunched, r.BackupWon, r.TransportEstUS, r.SleptUS, r.TimingAnomaly,

		r.CandidateSetSize, r.Scanned, recordutil.JsonbParam(r.GateRejections), r.RunnerUpProviderID, r.RunnerUpCostMs, r.NearTiePoolSize,
		r.SelectionPath, r.BestIdleProviderID, r.BestIdleTTFTMs, r.PredictedTTFTMs, r.RawTTFTMs, r.PredictedDecodeTPS,
		r.SnapshotAgeMs, r.PendingForModel, r.TotalPending, r.CapacityRateMs, r.CacheDiscountMs,
		r.ShadowWouldShed, r.ShadowIdleAlternative, r.LockWaitUS, r.ScanUS, r.AdmitUS, r.PreflightUS,
		r.TTFTCalibrationRatio, r.PrefillDecodeRatio, r.QueuePositionAtEnqueue, r.QueueDepthAtEnqueue, r.DrainTrigger,
		recordutil.JsonbParam(r.Candidates),

		r.ProvTotalUS, r.ProvFirstDeltaUS, r.ProvEngineSubmitUS, r.ProvEngineAdmittedUS, r.ProvPromptPrepUS, r.ProvLoadWaitUS,
		r.ProvLoadCold, r.ProvRunningAtAdmit, r.ProvWaitingAtAdmit, r.ProvKVBytesInUseAtAdmit, r.ProvCancelStage,
		r.EngQueueWaitNS, r.EngFirstTokenNS, r.EngPromptComputedNS, r.EngPrefillChunks, r.EngDecodeSteps, r.EngMTPAccepted,
		r.EngFinishReason, recordutil.JsonbParam(r.ProviderProfile), r.ProviderProfileValid, r.ProviderProfileInvalidReason, r.ProviderProfileConsistent,

		createdAt,
	}
}

// requestProfileScanTargets returns the Scan destinations for one
// request_profiles row in requestProfileColumns order. JSONB columns are
// scanned into the three []byte slots so NULL lands as nil (pgx scans NULL
// jsonb into a nil []byte); the caller copies non-empty ones into r.
func requestProfileScanTargets(r *contracts.RequestProfileRecord, gate, candidates, providerProfile *[]byte) []any {
	return []any{
		&r.CoordRequestID, &r.RequestID, &r.Attempt, &r.BackupOf, &r.Winning, &r.Endpoint, &r.Stream,
		&r.Model, &r.PublicModel, &r.ProviderID, &r.ProviderVersion, &r.ChipFamily, &r.KVBackend,
		&r.FinalStatus, &r.ErrorReason, &r.TerminalCause, &r.ClientOutcome, &r.ProviderOutcome, &r.ClientGonePhase,
		&r.FirstContentBudgetMs, &r.AdmissionMode, &r.PredictiveBypass, &r.ReservationTTFTCeilingMs, &r.DispatchBudgetMs,
		&r.EstimatedPromptTokens, &r.RequestedMaxTokens, &r.RequiresVision, &r.HasTools, &r.ReceivedAt,

		&r.AuthDoneUS, &r.RatelimitDoneUS, &r.SealedOpenUS, &r.HandlerEntryUS, &r.ParsedUS, &r.ReservedUS, &r.MediaFetchedUS,
		&r.PreflightDoneUS, &r.PlanDoneUS, &r.AttemptStartUS, &r.ReserveLockAcquiredUS, &r.ReserveDoneUS, &r.QueuedUS, &r.DequeuedUS,
		&r.TopupDoneUS, &r.EncryptedUS, &r.WriteSubmittedUS, &r.WriteDequeuedUS, &r.WriteDoneUS, &r.AcceptedUS,
		&r.FirstChunkIngressUS, &r.FirstChunkDequeuedUS, &r.FirstContentIngressUS, &r.FirstContentUS, &r.HeadersWrittenUS,
		&r.FirstFlushUS, &r.LastFlushUS, &r.ClientGoneUS, &r.CancelSentUS, &r.CompleteIngressUS, &r.DoneFlushedUS, &r.FinalizedUS,
		&r.SettleDBUS, &r.DBUS, &r.DBCalls,

		&r.BodyBytes, &r.SealedBodyBytes, &r.AuthKind, &r.AuthDBRead, &r.ReserveMode, &r.MediaItems, &r.MediaBytes,
		&r.PreflightOutcome, &r.PlanOutcome, &r.ChunksIn, &r.ChunksOut, &r.BytesOut, &r.DecryptUSTotal, &r.MaxChunkGapUS,
		&r.HeldPreambleChunks, &r.ClientWriteErr, &r.AttemptsTotal, &r.FailedAttempts, &r.FailedAttemptsUS,
		&r.BackupLaunched, &r.BackupWon, &r.TransportEstUS, &r.SleptUS, &r.TimingAnomaly,

		&r.CandidateSetSize, &r.Scanned, gate, &r.RunnerUpProviderID, &r.RunnerUpCostMs, &r.NearTiePoolSize,
		&r.SelectionPath, &r.BestIdleProviderID, &r.BestIdleTTFTMs, &r.PredictedTTFTMs, &r.RawTTFTMs, &r.PredictedDecodeTPS,
		&r.SnapshotAgeMs, &r.PendingForModel, &r.TotalPending, &r.CapacityRateMs, &r.CacheDiscountMs,
		&r.ShadowWouldShed, &r.ShadowIdleAlternative, &r.LockWaitUS, &r.ScanUS, &r.AdmitUS, &r.PreflightUS,
		&r.TTFTCalibrationRatio, &r.PrefillDecodeRatio, &r.QueuePositionAtEnqueue, &r.QueueDepthAtEnqueue, &r.DrainTrigger,
		candidates,

		&r.ProvTotalUS, &r.ProvFirstDeltaUS, &r.ProvEngineSubmitUS, &r.ProvEngineAdmittedUS, &r.ProvPromptPrepUS, &r.ProvLoadWaitUS,
		&r.ProvLoadCold, &r.ProvRunningAtAdmit, &r.ProvWaitingAtAdmit, &r.ProvKVBytesInUseAtAdmit, &r.ProvCancelStage,
		&r.EngQueueWaitNS, &r.EngFirstTokenNS, &r.EngPromptComputedNS, &r.EngPrefillChunks, &r.EngDecodeSteps, &r.EngMTPAccepted,
		&r.EngFinishReason, providerProfile, &r.ProviderProfileValid, &r.ProviderProfileInvalidReason, &r.ProviderProfileConsistent,

		&r.CreatedAt,
	}
}

// fleetSnapshotColumns is the fleet_snapshots column list (without id) in the
// one order shared by CopyFrom, the SELECT and the scan.
var fleetSnapshotColumns = []string{
	"sampled_at", "provider_id", "model", "eligibility_reason", "slot_state",
	"num_running", "num_waiting", "queued_prefill_tokens", "partial_prefill_rows",
	"active_token_budget_used", "active_token_budget_max", "kv_bytes_in_use", "kv_bytes_capacity",
	"observed_decode_tps", "observed_prefill_tps", "isolated_prefill_tps", "ewma_initialized",
	"max_concurrency", "pending_count", "effective_cap",
	"cooldown_active", "breaker_open", "clamp_active", "ejected",
	"gpu_memory_active_gb", "gpu_memory_peak_gb", "free_for_load_gb", "memory_pressure", "cpu_usage",
	"thermal_state", "low_power_mode", "memory_pressure_level",
	"steps_executed", "step_wall_ns_total", "decode_rows_total", "prefill_tokens_total",
	"mtp_rounds_total", "mtp_proposed_total", "mtp_accepted_total",
	"heartbeat_age_ms", "wedge_suspected", "eval_in_flight_ms",
	"requests_served", "tokens_generated", "cancellations_received", "cancellations_before_output", "cancellations_partial_complete",
	"generation_errors_after_output", "chunk_encryption_errors", "stream_closed_without_terminal", "cancel_during_model_load", "usage_gaps",
	"cancel_stage_pre_accept_total", "cancel_stage_pre_engine_total", "cancel_stage_prefill_total", "cancel_stage_decode_total",
	"cancel_stage_post_terminal_total", "tokens_after_cancel_total", "cancel_abort_ns_sum",
	"queue_depth_total", "queue_depth_by_model", "inflight_requests", "reserve_lock_wait_p95_us",
	"profile_sink_depth", "profile_sink_dropped_total", "route_sink_dropped_total", "unknown_request_frames_total", "goroutines",
	"provider_version", "model_vision", "template_render_ok",
}

// fleetSnapshotValues returns the CopyFrom row for f in fleetSnapshotColumns
// order. sampledAt is the resolved sampled_at value.
func fleetSnapshotValues(f *contracts.FleetSnapshotRow, sampledAt time.Time) []any {
	return []any{
		sampledAt, f.ProviderID, f.Model, f.EligibilityReason, f.SlotState,
		f.NumRunning, f.NumWaiting, f.QueuedPrefillTokens, f.PartialPrefillRows,
		f.ActiveTokenBudgetUsed, f.ActiveTokenBudgetMax, f.KVBytesInUse, f.KVBytesCapacity,
		f.ObservedDecodeTPS, f.ObservedPrefillTPS, f.IsolatedPrefillTPS, f.EWMAInitialized,
		f.MaxConcurrency, f.PendingCount, f.EffectiveCap,
		f.CooldownActive, f.BreakerOpen, f.ClampActive, f.Ejected,
		f.GPUMemoryActiveGB, f.GPUMemoryPeakGB, f.FreeForLoadGB, f.MemoryPressure, f.CPUUsage,
		f.ThermalState, f.LowPowerMode, f.MemoryPressureLevel,
		f.StepsExecuted, f.StepWallNSTotal, f.DecodeRowsTotal, f.PrefillTokensTotal,
		f.MTPRoundsTotal, f.MTPProposedTotal, f.MTPAcceptedTotal,
		f.HeartbeatAgeMs, f.WedgeSuspected, f.EvalInFlightMs,
		f.RequestsServed, f.TokensGenerated, f.CancellationsReceived, f.CancellationsBeforeOutput, f.CancellationsPartialComplete,
		f.GenerationErrorsAfterOutput, f.ChunkEncryptionErrors, f.StreamClosedWithoutTerminal, f.CancelDuringModelLoad, f.UsageGaps,
		f.CancelStagePreAcceptTotal, f.CancelStagePreEngineTotal, f.CancelStagePrefillTotal, f.CancelStageDecodeTotal,
		f.CancelStagePostTerminalTotal, f.TokensAfterCancelTotal, f.CancelAbortNSSum,
		f.QueueDepthTotal, recordutil.JsonbParam(f.QueueDepthByModel), f.InflightRequests, f.ReserveLockWaitP95US,
		f.ProfileSinkDepth, f.ProfileSinkDroppedTotal, f.RouteSinkDroppedTotal, f.UnknownRequestFramesTotal, f.Goroutines,
		f.ProviderVersion, f.ModelVision, f.TemplateRenderOK,
	}
}

// fleetSnapshotScanTargets returns the Scan destinations for one
// fleet_snapshots row in fleetSnapshotColumns order.
func fleetSnapshotScanTargets(f *contracts.FleetSnapshotRow, queueDepthByModel *[]byte) []any {
	return []any{
		&f.SampledAt, &f.ProviderID, &f.Model, &f.EligibilityReason, &f.SlotState,
		&f.NumRunning, &f.NumWaiting, &f.QueuedPrefillTokens, &f.PartialPrefillRows,
		&f.ActiveTokenBudgetUsed, &f.ActiveTokenBudgetMax, &f.KVBytesInUse, &f.KVBytesCapacity,
		&f.ObservedDecodeTPS, &f.ObservedPrefillTPS, &f.IsolatedPrefillTPS, &f.EWMAInitialized,
		&f.MaxConcurrency, &f.PendingCount, &f.EffectiveCap,
		&f.CooldownActive, &f.BreakerOpen, &f.ClampActive, &f.Ejected,
		&f.GPUMemoryActiveGB, &f.GPUMemoryPeakGB, &f.FreeForLoadGB, &f.MemoryPressure, &f.CPUUsage,
		&f.ThermalState, &f.LowPowerMode, &f.MemoryPressureLevel,
		&f.StepsExecuted, &f.StepWallNSTotal, &f.DecodeRowsTotal, &f.PrefillTokensTotal,
		&f.MTPRoundsTotal, &f.MTPProposedTotal, &f.MTPAcceptedTotal,
		&f.HeartbeatAgeMs, &f.WedgeSuspected, &f.EvalInFlightMs,
		&f.RequestsServed, &f.TokensGenerated, &f.CancellationsReceived, &f.CancellationsBeforeOutput, &f.CancellationsPartialComplete,
		&f.GenerationErrorsAfterOutput, &f.ChunkEncryptionErrors, &f.StreamClosedWithoutTerminal, &f.CancelDuringModelLoad, &f.UsageGaps,
		&f.CancelStagePreAcceptTotal, &f.CancelStagePreEngineTotal, &f.CancelStagePrefillTotal, &f.CancelStageDecodeTotal,
		&f.CancelStagePostTerminalTotal, &f.TokensAfterCancelTotal, &f.CancelAbortNSSum,
		&f.QueueDepthTotal, queueDepthByModel, &f.InflightRequests, &f.ReserveLockWaitP95US,
		&f.ProfileSinkDepth, &f.ProfileSinkDroppedTotal, &f.RouteSinkDroppedTotal, &f.UnknownRequestFramesTotal, &f.Goroutines,
		&f.ProviderVersion, &f.ModelVision, &f.TemplateRenderOK,
	}
}
