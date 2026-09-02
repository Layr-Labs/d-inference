package store

import (
	"encoding/json"
	"time"
)

// RequestProfileRecord is one row of request_profiles: one row per dispatched
// attempt (pre-dispatch rejections never produce a row). Every *US/*NS offset
// is a pointer measured in microseconds/nanoseconds from the request's t0 and
// nil means "did not happen". Enum-typed strings are closed vocabularies
// folded by the api layer before they reach the store; the store never
// validates content and never adds free-form provider strings.
//
// Nullability mirrors Go pointer-ness exactly: pointer and json.RawMessage
// fields are nullable columns, every other field is NOT NULL with a zero
// default, so a value of 0/""/false round-trips as itself and nil as NULL.
type RequestProfileRecord struct {
	CoordRequestID       string `json:"coord_request_id"`
	RequestID            string `json:"request_id"` // attempt UUID (joins inference_routes)
	Attempt              int    `json:"attempt"`
	BackupOf             string `json:"backup_of,omitempty"`
	Winning              bool   `json:"winning"`
	Endpoint             string `json:"endpoint"` // mux pattern
	Stream               bool   `json:"stream"`
	Model                string `json:"model"`
	PublicModel          string `json:"public_model"`
	ProviderID           string `json:"provider_id"`
	ProviderVersion      string `json:"provider_version"`
	ChipFamily           string `json:"chip_family"`
	KVBackend            string `json:"kv_backend"`
	FinalStatus          string `json:"final_status"`
	ErrorReason          string `json:"error_reason"`
	TerminalCause        string `json:"terminal_cause"`
	ClientOutcome        string `json:"client_outcome"`
	ProviderOutcome      string `json:"provider_outcome"`
	ClientGonePhase      string `json:"client_gone_phase"`
	FirstContentBudgetMs int    `json:"first_content_budget_ms"`
	AdmissionMode        string `json:"admission_mode"`
	// Request shape as the router saw it (the estimate, not the tokenizer's
	// count): what routingsim replays an arrival from.
	EstimatedPromptTokens int       `json:"estimated_prompt_tokens"`
	RequestedMaxTokens    int       `json:"requested_max_tokens"`
	RequiresVision        bool      `json:"requires_vision"`
	HasTools              bool      `json:"has_tools"`
	ReceivedAt            time.Time `json:"received_at"`

	// Coordinator offsets, microseconds from t0 (nil = never happened).
	AuthDoneUS            *int64 `json:"auth_done_us"`
	RatelimitDoneUS       *int64 `json:"ratelimit_done_us"`
	SealedOpenUS          *int64 `json:"sealed_open_us"`
	HandlerEntryUS        *int64 `json:"handler_entry_us"`
	ParsedUS              *int64 `json:"parsed_us"`
	ReservedUS            *int64 `json:"reserved_us"`
	MediaFetchedUS        *int64 `json:"media_fetched_us"`
	PreflightDoneUS       *int64 `json:"preflight_done_us"`
	PlanDoneUS            *int64 `json:"plan_done_us"`
	AttemptStartUS        *int64 `json:"attempt_start_us"`
	ReserveLockAcquiredUS *int64 `json:"reserve_lock_acquired_us"`
	ReserveDoneUS         *int64 `json:"reserve_done_us"`
	QueuedUS              *int64 `json:"queued_us"`
	DequeuedUS            *int64 `json:"dequeued_us"`
	TopupDoneUS           *int64 `json:"topup_done_us"`
	EncryptedUS           *int64 `json:"encrypted_us"`
	WriteSubmittedUS      *int64 `json:"write_submitted_us"`
	WriteDequeuedUS       *int64 `json:"write_dequeued_us"`
	WriteDoneUS           *int64 `json:"write_done_us"`
	AcceptedUS            *int64 `json:"accepted_us"`
	FirstChunkIngressUS   *int64 `json:"first_chunk_ingress_us"`
	FirstChunkDequeuedUS  *int64 `json:"first_chunk_dequeued_us"`
	FirstContentIngressUS *int64 `json:"first_content_ingress_us"`
	FirstContentUS        *int64 `json:"first_content_us"`
	HeadersWrittenUS      *int64 `json:"headers_written_us"`
	FirstFlushUS          *int64 `json:"first_flush_us"`
	LastFlushUS           *int64 `json:"last_flush_us"`
	ClientGoneUS          *int64 `json:"client_gone_us"`
	CancelSentUS          *int64 `json:"cancel_sent_us"`
	CompleteIngressUS     *int64 `json:"complete_ingress_us"`
	DoneFlushedUS         *int64 `json:"done_flushed_us"`
	FinalizedUS           *int64 `json:"finalized_us"`
	SettleDBUS            *int64 `json:"settle_db_us"`
	DBUS                  *int64 `json:"db_us"`
	DBCalls               int    `json:"db_calls"`

	BodyBytes          int    `json:"body_bytes"`
	SealedBodyBytes    int    `json:"sealed_body_bytes"`
	AuthKind           string `json:"auth_kind"`
	AuthDBRead         bool   `json:"auth_db_read"`
	ReserveMode        string `json:"reserve_mode"`
	MediaItems         int    `json:"media_items"`
	MediaBytes         int64  `json:"media_bytes"`
	PreflightOutcome   string `json:"preflight_outcome"`
	PlanOutcome        string `json:"plan_outcome"`
	ChunksIn           int    `json:"chunks_in"`
	ChunksOut          int    `json:"chunks_out"`
	BytesOut           int64  `json:"bytes_out"`
	DecryptUSTotal     int64  `json:"decrypt_us_total"`
	MaxChunkGapUS      int64  `json:"max_chunk_gap_us"`
	HeldPreambleChunks int    `json:"held_preamble_chunks"`
	ClientWriteErr     bool   `json:"client_write_err"`
	AttemptsTotal      int    `json:"attempts_total"`
	FailedAttempts     int    `json:"failed_attempts"`
	FailedAttemptsUS   int64  `json:"failed_attempts_us"`
	BackupLaunched     bool   `json:"backup_launched"`
	BackupWon          bool   `json:"backup_won"`
	TransportEstUS     *int64 `json:"transport_est_us"`
	SleptUS            *int64 `json:"slept_us"`
	TimingAnomaly      bool   `json:"timing_anomaly"`

	// Routing context.
	CandidateSetSize       int             `json:"candidate_set_size"`
	Scanned                int             `json:"scanned"`
	GateRejections         json.RawMessage `json:"gate_rejections,omitempty"` // {"reason":count}
	RunnerUpProviderID     string          `json:"runner_up_provider_id"`
	RunnerUpCostMs         float64         `json:"runner_up_cost_ms"`
	NearTiePoolSize        int             `json:"near_tie_pool_size"`
	SelectionPath          string          `json:"selection_path"`
	BestIdleProviderID     string          `json:"best_idle_provider_id"`
	BestIdleTTFTMs         float64         `json:"best_idle_ttft_ms"`
	PredictedTTFTMs        float64         `json:"predicted_ttft_ms"`
	RawTTFTMs              float64         `json:"raw_ttft_ms"`
	PredictedDecodeTPS     float64         `json:"predicted_decode_tps"`
	SnapshotAgeMs          int             `json:"snapshot_age_ms"`
	PendingForModel        int             `json:"pending_for_model"`
	TotalPending           int             `json:"total_pending"`
	CapacityRateMs         float64         `json:"capacity_rate_ms"`
	CacheDiscountMs        float64         `json:"cache_discount_ms"`
	ShadowWouldShed        *bool           `json:"shadow_would_shed"`
	ShadowIdleAlternative  *bool           `json:"shadow_idle_alternative"`
	LockWaitUS             int64           `json:"lock_wait_us"`
	ScanUS                 int64           `json:"scan_us"`
	AdmitUS                int64           `json:"admit_us"`
	PreflightUS            int64           `json:"preflight_us"`
	TTFTCalibrationRatio   float64         `json:"ttft_calibration_ratio"`
	PrefillDecodeRatio     float64         `json:"prefill_decode_ratio"`
	QueuePositionAtEnqueue int             `json:"queue_position_at_enqueue"`
	QueueDepthAtEnqueue    int             `json:"queue_depth_at_enqueue"`
	DrainTrigger           string          `json:"drain_trigger"`
	Candidates             json.RawMessage `json:"candidates,omitempty"` // top-4 array

	// Provider profile: hot typed columns + long tail JSONB.
	ProvTotalUS                  *int64          `json:"prov_total_us"`
	ProvFirstDeltaUS             *int64          `json:"prov_first_delta_us"`
	ProvEngineSubmitUS           *int64          `json:"prov_engine_submit_us"`
	ProvEngineAdmittedUS         *int64          `json:"prov_engine_admitted_us"`
	ProvPromptPrepUS             *int64          `json:"prov_prompt_prep_us"`
	ProvLoadWaitUS               *int64          `json:"prov_load_wait_us"`
	ProvLoadCold                 *bool           `json:"prov_load_cold"`
	ProvRunningAtAdmit           *int            `json:"prov_running_at_admit"`
	ProvWaitingAtAdmit           *int            `json:"prov_waiting_at_admit"`
	ProvKVBytesInUseAtAdmit      *int64          `json:"prov_kv_bytes_in_use_at_admit"`
	ProvCancelStage              string          `json:"prov_cancel_stage"`
	EngQueueWaitNS               *int64          `json:"eng_queue_wait_ns"`
	EngFirstTokenNS              *int64          `json:"eng_first_token_ns"`
	EngPromptComputedNS          *int64          `json:"eng_prompt_computed_ns"`
	EngPrefillChunks             *int            `json:"eng_prefill_chunks"`
	EngDecodeSteps               *int            `json:"eng_decode_steps"`
	EngMTPAccepted               *int            `json:"eng_mtp_accepted"`
	EngFinishReason              string          `json:"eng_finish_reason"`
	ProviderProfile              json.RawMessage `json:"provider_profile,omitempty"`
	ProviderProfileValid         bool            `json:"provider_profile_valid"`
	ProviderProfileInvalidReason string          `json:"provider_profile_invalid_reason"`
	ProviderProfileConsistent    *bool           `json:"provider_profile_consistent"`

	CreatedAt time.Time `json:"created_at"`
}

// FleetSnapshotRow is one row of fleet_snapshots: one row per (provider, model
// slot) per sampler tick, plus one coordinator row per tick with
// ProviderID == "coordinator" carrying the coordinator-only columns.
// SlotState and EligibilityReason are closed vocabularies produced by the
// registry (registry.SlotStateFold / the gate-reason enum).
type FleetSnapshotRow struct {
	SampledAt         time.Time `json:"sampled_at"`
	ProviderID        string    `json:"provider_id"`
	Model             string    `json:"model"`
	EligibilityReason string    `json:"eligibility_reason"`
	SlotState         string    `json:"slot_state"` // MUST be produced via registry.SlotStateFold (closed vocabulary)

	NumRunning            int     `json:"num_running"`
	NumWaiting            int     `json:"num_waiting"`
	QueuedPrefillTokens   int     `json:"queued_prefill_tokens"`
	PartialPrefillRows    int     `json:"partial_prefill_rows"`
	ActiveTokenBudgetUsed int64   `json:"active_token_budget_used"`
	ActiveTokenBudgetMax  int64   `json:"active_token_budget_max"`
	KVBytesInUse          int64   `json:"kv_bytes_in_use"`
	KVBytesCapacity       int64   `json:"kv_bytes_capacity"`
	ObservedDecodeTPS     float64 `json:"observed_decode_tps"`
	ObservedPrefillTPS    float64 `json:"observed_prefill_tps"`
	IsolatedPrefillTPS    float64 `json:"isolated_prefill_tps"`
	EWMAInitialized       *bool   `json:"ewma_initialized"`
	MaxConcurrency        int     `json:"max_concurrency"`
	PendingCount          int     `json:"pending_count"`
	EffectiveCap          int     `json:"effective_cap"`
	CooldownActive        bool    `json:"cooldown_active"`
	BreakerOpen           bool    `json:"breaker_open"`
	ClampActive           bool    `json:"clamp_active"`
	Ejected               bool    `json:"ejected"`
	GPUMemoryActiveGB     float64 `json:"gpu_memory_active_gb"`
	GPUMemoryPeakGB       float64 `json:"gpu_memory_peak_gb"`
	FreeForLoadGB         float64 `json:"free_for_load_gb"`
	MemoryPressure        float64 `json:"memory_pressure"`
	CPUUsage              float64 `json:"cpu_usage"`
	ThermalState          string  `json:"thermal_state"`
	LowPowerMode          *bool   `json:"low_power_mode"`
	MemoryPressureLevel   string  `json:"memory_pressure_level"`
	StepsExecuted         int64   `json:"steps_executed"`
	StepWallNSTotal       int64   `json:"step_wall_ns_total"`
	DecodeRowsTotal       int64   `json:"decode_rows_total"`
	PrefillTokensTotal    int64   `json:"prefill_tokens_total"`
	MTPRoundsTotal        int64   `json:"mtp_rounds_total"`
	MTPProposedTotal      int64   `json:"mtp_proposed_total"`
	MTPAcceptedTotal      int64   `json:"mtp_accepted_total"`
	HeartbeatAgeMs        int     `json:"heartbeat_age_ms"`
	WedgeSuspected        bool    `json:"wedge_suspected"`
	EvalInFlightMs        int64   `json:"eval_in_flight_ms"`

	// HeartbeatStats cumulative counters (as reported).
	RequestsServed               int64 `json:"requests_served"`
	TokensGenerated              int64 `json:"tokens_generated"`
	CancellationsReceived        int64 `json:"cancellations_received"`
	CancellationsBeforeOutput    int64 `json:"cancellations_before_output"`
	CancellationsPartialComplete int64 `json:"cancellations_partial_complete"`
	GenerationErrorsAfterOutput  int64 `json:"generation_errors_after_output"`
	ChunkEncryptionErrors        int64 `json:"chunk_encryption_errors"`
	StreamClosedWithoutTerminal  int64 `json:"stream_closed_without_terminal"`
	CancelDuringModelLoad        int64 `json:"cancel_during_model_load"`
	UsageGaps                    int64 `json:"usage_gaps"`
	CancelStagePreAcceptTotal    int64 `json:"cancel_stage_pre_accept_total"`
	CancelStagePreEngineTotal    int64 `json:"cancel_stage_pre_engine_total"`
	CancelStagePrefillTotal      int64 `json:"cancel_stage_prefill_total"`
	CancelStageDecodeTotal       int64 `json:"cancel_stage_decode_total"`
	CancelStagePostTerminalTotal int64 `json:"cancel_stage_post_terminal_total"`
	TokensAfterCancelTotal       int64 `json:"tokens_after_cancel_total"`
	CancelAbortNSSum             int64 `json:"cancel_abort_ns_sum"`

	// Coordinator row only.
	QueueDepthTotal           int             `json:"queue_depth_total"`
	QueueDepthByModel         json.RawMessage `json:"queue_depth_by_model,omitempty"`
	InflightRequests          int             `json:"inflight_requests"`
	ReserveLockWaitP95US      int64           `json:"reserve_lock_wait_p95_us"`
	ProfileSinkDepth          int             `json:"profile_sink_depth"`
	ProfileSinkDroppedTotal   int64           `json:"profile_sink_dropped_total"`
	RouteSinkDroppedTotal     int64           `json:"route_sink_dropped_total"`
	UnknownRequestFramesTotal int64           `json:"unknown_request_frames_total"`
	Goroutines                int             `json:"goroutines"`

	// Capability gating, so a routing replay (registry/routingsim) can
	// reconstruct the tools version floor and the vision gate. Provider rows
	// only (zero/NULL on the coordinator row); added after the initial DDL, so
	// they trail the column list and an upgraded database gains them through
	// ALTER TABLE ... ADD COLUMN IF NOT EXISTS with the same physical order.
	// ProviderVersion MUST be produced via registry.ProviderVersionFold (a
	// bounded semver or the "invalid" sentinel; "" when unreported). The two
	// model flags are the slot model's advertised ModelInfo.IsVision /
	// TemplateRenderOK (nil = the provider reported no opinion).
	ProviderVersion  string `json:"provider_version"`
	ModelVision      bool   `json:"model_vision"`
	TemplateRenderOK *bool  `json:"template_render_ok"`
}

// requestProfileColumns is the request_profiles column list (without the
// BIGSERIAL id) in the one order shared by the INSERT, the SELECT and the scan.
// requestProfileValues and requestProfileScanTargets MUST stay in this order;
// TestRequestProfileColumnsStayAligned pins the three together.
var requestProfileColumns = []string{
	"coord_request_id", "request_id", "attempt", "backup_of", "winning", "endpoint", "stream",
	"model", "public_model", "provider_id", "provider_version", "chip_family", "kv_backend",
	"final_status", "error_reason", "terminal_cause", "client_outcome", "provider_outcome", "client_gone_phase",
	"first_content_budget_ms", "admission_mode",
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

// jsonbParam returns nil (SQL NULL) for an empty RawMessage so an empty value
// never reaches JSONB as an invalid zero-length document (mirrors the
// request_rejections params handling).
func jsonbParam(raw json.RawMessage) json.RawMessage {
	if len(raw) == 0 {
		return nil
	}
	return raw
}

// requestProfileValues returns the INSERT parameters for r in
// requestProfileColumns order. createdAt is the resolved created_at value.
func requestProfileValues(r *RequestProfileRecord, createdAt time.Time) []any {
	return []any{
		r.CoordRequestID, r.RequestID, r.Attempt, r.BackupOf, r.Winning, r.Endpoint, r.Stream,
		r.Model, r.PublicModel, r.ProviderID, r.ProviderVersion, r.ChipFamily, r.KVBackend,
		r.FinalStatus, r.ErrorReason, r.TerminalCause, r.ClientOutcome, r.ProviderOutcome, r.ClientGonePhase,
		r.FirstContentBudgetMs, r.AdmissionMode,
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

		r.CandidateSetSize, r.Scanned, jsonbParam(r.GateRejections), r.RunnerUpProviderID, r.RunnerUpCostMs, r.NearTiePoolSize,
		r.SelectionPath, r.BestIdleProviderID, r.BestIdleTTFTMs, r.PredictedTTFTMs, r.RawTTFTMs, r.PredictedDecodeTPS,
		r.SnapshotAgeMs, r.PendingForModel, r.TotalPending, r.CapacityRateMs, r.CacheDiscountMs,
		r.ShadowWouldShed, r.ShadowIdleAlternative, r.LockWaitUS, r.ScanUS, r.AdmitUS, r.PreflightUS,
		r.TTFTCalibrationRatio, r.PrefillDecodeRatio, r.QueuePositionAtEnqueue, r.QueueDepthAtEnqueue, r.DrainTrigger,
		jsonbParam(r.Candidates),

		r.ProvTotalUS, r.ProvFirstDeltaUS, r.ProvEngineSubmitUS, r.ProvEngineAdmittedUS, r.ProvPromptPrepUS, r.ProvLoadWaitUS,
		r.ProvLoadCold, r.ProvRunningAtAdmit, r.ProvWaitingAtAdmit, r.ProvKVBytesInUseAtAdmit, r.ProvCancelStage,
		r.EngQueueWaitNS, r.EngFirstTokenNS, r.EngPromptComputedNS, r.EngPrefillChunks, r.EngDecodeSteps, r.EngMTPAccepted,
		r.EngFinishReason, jsonbParam(r.ProviderProfile), r.ProviderProfileValid, r.ProviderProfileInvalidReason, r.ProviderProfileConsistent,

		createdAt,
	}
}

// requestProfileScanTargets returns the Scan destinations for one
// request_profiles row in requestProfileColumns order. JSONB columns are
// scanned into the three []byte slots so NULL lands as nil (pgx scans NULL
// jsonb into a nil []byte); the caller copies non-empty ones into r.
func requestProfileScanTargets(r *RequestProfileRecord, gate, candidates, providerProfile *[]byte) []any {
	return []any{
		&r.CoordRequestID, &r.RequestID, &r.Attempt, &r.BackupOf, &r.Winning, &r.Endpoint, &r.Stream,
		&r.Model, &r.PublicModel, &r.ProviderID, &r.ProviderVersion, &r.ChipFamily, &r.KVBackend,
		&r.FinalStatus, &r.ErrorReason, &r.TerminalCause, &r.ClientOutcome, &r.ProviderOutcome, &r.ClientGonePhase,
		&r.FirstContentBudgetMs, &r.AdmissionMode,
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
func fleetSnapshotValues(f *FleetSnapshotRow, sampledAt time.Time) []any {
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
		f.QueueDepthTotal, jsonbParam(f.QueueDepthByModel), f.InflightRequests, f.ReserveLockWaitP95US,
		f.ProfileSinkDepth, f.ProfileSinkDroppedTotal, f.RouteSinkDroppedTotal, f.UnknownRequestFramesTotal, f.Goroutines,
		f.ProviderVersion, f.ModelVision, f.TemplateRenderOK,
	}
}

// fleetSnapshotScanTargets returns the Scan destinations for one
// fleet_snapshots row in fleetSnapshotColumns order.
func fleetSnapshotScanTargets(f *FleetSnapshotRow, queueDepthByModel *[]byte) []any {
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
