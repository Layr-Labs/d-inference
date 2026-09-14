package profiler

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// StoredInferenceProfile is the persisted (JSONB) shape of a provider profile.
// It mirrors protocol.InferenceProfile key-for-key but is a distinct type so
// the wire struct can never be persisted by accident, and so the reflective
// closed-struct test guards exactly what reaches the store. Pointers keep
// NULL (absent) distinguishable from 0.
type StoredInferenceProfile struct {
	Schema *int   `json:"schema,omitempty"`
	WallMS *int64 `json:"wall_ms,omitempty"` // untrusted provider wall anchor, stored verbatim

	DequeuedUS        *int64 `json:"dequeued_us,omitempty"`
	DecryptedUS       *int64 `json:"decrypted_us,omitempty"`
	ParsedUS          *int64 `json:"parsed_us,omitempty"`
	AdmissionUS       *int64 `json:"admission_us,omitempty"`
	AcceptedSentUS    *int64 `json:"accepted_sent_us,omitempty"`
	LoadWaitStartUS   *int64 `json:"load_wait_start_us,omitempty"`
	LoadWaitEndUS     *int64 `json:"load_wait_end_us,omitempty"`
	TaskSpawnedUS     *int64 `json:"task_spawned_us,omitempty"`
	PromptPrepStartUS *int64 `json:"prompt_prep_start_us,omitempty"`
	PromptPrepEndUS   *int64 `json:"prompt_prep_end_us,omitempty"`
	EngineSubmitUS    *int64 `json:"engine_submit_us,omitempty"`
	EngineAdmittedUS  *int64 `json:"engine_admitted_us,omitempty"`
	FirstDeltaUS      *int64 `json:"first_delta_us,omitempty"`
	FirstFrameUS      *int64 `json:"first_frame_us,omitempty"`
	LastDeltaUS       *int64 `json:"last_delta_us,omitempty"`
	TerminalBuiltUS   *int64 `json:"terminal_built_us,omitempty"`
	TerminalSentUS    *int64 `json:"terminal_sent_us,omitempty"`
	CancelReceivedUS  *int64 `json:"cancel_received_us,omitempty"`
	CancelAbortedUS   *int64 `json:"cancel_aborted_us,omitempty"`
	TotalUS           *int64 `json:"total_us,omitempty"`

	ToolConstraintUS         *int64 `json:"tool_constraint_us,omitempty"`
	VisionPrepUS             *int64 `json:"vision_prep_us,omitempty"`
	SSDStageUS               *int64 `json:"ssd_stage_us,omitempty"`
	KVReserveUS              *int64 `json:"kv_reserve_us,omitempty"`
	FlushUS                  *int64 `json:"flush_us,omitempty"`
	SESignUS                 *int64 `json:"se_sign_us,omitempty"`
	SleptUS                  *int64 `json:"slept_us,omitempty"`
	ProjectedServiceUS       *int64 `json:"projected_service_us,omitempty"`
	BudgetRemainingAtAdmitUS *int64 `json:"budget_remaining_at_admit_us,omitempty"`

	PromptTokens               *int `json:"prompt_tokens,omitempty"`
	FramesEmitted              *int `json:"frames_emitted,omitempty"`
	RunningAtAdmit             *int `json:"running_at_admit,omitempty"`
	WaitingAtAdmit             *int `json:"waiting_at_admit,omitempty"`
	QueuedPrefillTokensAtAdmit *int `json:"queued_prefill_tokens_at_admit,omitempty"`
	StepsAtSubmit              *int `json:"steps_at_submit,omitempty"`
	StepsAtFinish              *int `json:"steps_at_finish,omitempty"`
	ProjectedPrefillTokens     *int `json:"projected_prefill_tokens,omitempty"`
	ProjectedDecodeTokens      *int `json:"projected_decode_tokens,omitempty"`
	PartialPrefillCap          *int `json:"partial_prefill_cap,omitempty"`
	TokensAfterCancel          *int `json:"tokens_after_cancel,omitempty"`

	BytesEmitted           *int64 `json:"bytes_emitted,omitempty"`
	KVBytesInUseAtAdmit    *int64 `json:"kv_bytes_in_use_at_admit,omitempty"`
	KVBytesCapacity        *int64 `json:"kv_bytes_capacity,omitempty"`
	MLXActiveBytesAtFinish *int64 `json:"mlx_active_bytes_at_finish,omitempty"`
	MLXPeakBytes           *int64 `json:"mlx_peak_bytes,omitempty"`

	UsageRecovered *bool `json:"usage_recovered,omitempty"`
	LoadCold       *bool `json:"load_cold,omitempty"`
	LoadParked     *bool `json:"load_parked,omitempty"`
	MTPActive      *bool `json:"mtp_active,omitempty"`
	LowPowerMode   *bool `json:"low_power_mode,omitempty"`

	DeadlineMode protocol.DeadlineMode `json:"deadline_mode,omitempty"`
	ThermalState protocol.ThermalState `json:"thermal_state,omitempty"`
	CancelStage  protocol.CancelStage  `json:"cancel_stage,omitempty"`

	DeadlineDecision *StoredDeadlineDecision `json:"deadline_decision,omitempty"`

	Engine *StoredEngineProfile `json:"engine,omitempty"`
}

// StoredEngineProfile is the persisted engine sub-object (see EngineProfile).
type StoredEngineProfile struct {
	AdmittedNS           *int64 `json:"admitted_ns,omitempty"`
	KVAllocatedNS        *int64 `json:"kv_allocated_ns,omitempty"`
	PrefillFirstLaunchNS *int64 `json:"prefill_first_launch_ns,omitempty"`
	PromptComputedNS     *int64 `json:"prompt_computed_ns,omitempty"`
	FirstTokenNS         *int64 `json:"first_token_ns,omitempty"`
	FinishedNS           *int64 `json:"finished_ns,omitempty"`

	Readmissions     *int `json:"readmissions,omitempty"`
	Preemptions      *int `json:"preemptions,omitempty"`
	CapacityRequeues *int `json:"capacity_requeues,omitempty"`

	PrefillChunks         *int `json:"prefill_chunks,omitempty"`
	PackedPrefillChunks   *int `json:"packed_prefill_chunks,omitempty"`
	VisionChunks          *int `json:"vision_chunks,omitempty"`
	SoloStripeChunks      *int `json:"solo_stripe_chunks,omitempty"`
	PrefillChunkTokensMax *int `json:"prefill_chunk_tokens_max,omitempty"`

	DecodeSteps        *int `json:"decode_steps,omitempty"`
	ChainedDecodeSteps *int `json:"chained_decode_steps,omitempty"`
	BatchRowsSum       *int `json:"batch_rows_sum,omitempty"`
	BatchRowsMin       *int `json:"batch_rows_min,omitempty"`
	BatchRowsMax       *int `json:"batch_rows_max,omitempty"`

	StepLatencyNSSum *int64 `json:"step_latency_ns_sum,omitempty"`
	StepLatencyNSMax *int64 `json:"step_latency_ns_max,omitempty"`

	MTPRounds   *int `json:"mtp_rounds,omitempty"`
	MTPProposed *int `json:"mtp_proposed,omitempty"`
	MTPAccepted *int `json:"mtp_accepted,omitempty"`

	PausedNS          *int64 `json:"paused_ns,omitempty"`
	PauseCount        *int   `json:"pause_count,omitempty"`
	DetokDelayFirstNS *int64 `json:"detok_delay_first_ns,omitempty"`
	PrefixLookupNS    *int64 `json:"prefix_lookup_ns,omitempty"`
	PrefixAdoptionNS  *int64 `json:"prefix_adoption_ns,omitempty"`

	FinishReason protocol.EngineFinishReason `json:"finish_reason,omitempty"`
}
