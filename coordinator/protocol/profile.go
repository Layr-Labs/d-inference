package protocol

// Provider-reported request profile and heartbeat telemetry (system profiler,
// slice 2). Wire contract: scratchpad CONTRACT-WIRE.md / docs system-profiler.
//
// Every numeric is a pointer with omitempty: absent means "did not happen" or
// "unknown" and must stay distinguishable from 0. Every string field is a
// closed enum with a Valid()/Fold() pair; the api layer folds unknown values
// to "other" before anything is persisted. There are no free-form strings.
//
// The `profile` object rides on inference_complete / inference_error as
// json.RawMessage (see InferenceCompleteMessage.Profile): the WS read loop
// only length-checks it, and InferenceProfile is the typed decode target used
// by api/profiler_provider.go on the profile sink worker. It never influences
// routing, health, billing, deadlines or client output.

// MaxInferenceProfileBytes caps the encoded `profile` object. The provider
// asserts it in tests; the coordinator rejects anything larger as
// invalid_reason=size before reading a single byte of it.
const MaxInferenceProfileBytes = 4096

// InferenceProfileSchema is the only schema version this coordinator accepts.
const InferenceProfileSchema = 1

// EnumOther is the fold target for every closed enum below.
const EnumOther = "other"

// DeadlineMode is the provider's admission deadline mode for the request.
type DeadlineMode string

const (
	DeadlineModeNone      DeadlineMode = "none"
	DeadlineModeProjected DeadlineMode = "projected"
	DeadlineModeLegacy    DeadlineMode = "legacy"
	DeadlineModeOther     DeadlineMode = EnumOther
)

// Valid reports membership in the closed vocabulary ("" is absent, not valid).
func (m DeadlineMode) Valid() bool {
	switch m {
	case DeadlineModeNone, DeadlineModeProjected, DeadlineModeLegacy, DeadlineModeOther:
		return true
	}
	return false
}

// Fold returns the value unchanged when valid or absent, else "other".
func (m DeadlineMode) Fold() DeadlineMode { return foldEnum(m, DeadlineModeOther) }

// ThermalState is the provider's thermal posture at the request's terminal.
type ThermalState string

const (
	ThermalStateNominal  ThermalState = "nominal"
	ThermalStateFair     ThermalState = "fair"
	ThermalStateSerious  ThermalState = "serious"
	ThermalStateCritical ThermalState = "critical"
	ThermalStateOther    ThermalState = EnumOther
)

// Valid reports membership in the closed vocabulary ("" is absent, not valid).
func (s ThermalState) Valid() bool {
	switch s {
	case ThermalStateNominal, ThermalStateFair, ThermalStateSerious, ThermalStateCritical, ThermalStateOther:
		return true
	}
	return false
}

// Fold returns the value unchanged when valid or absent, else "other".
func (s ThermalState) Fold() ThermalState { return foldEnum(s, ThermalStateOther) }

// CancelStage is the request lifecycle stage at which a cancel took effect.
type CancelStage string

const (
	CancelStageNone         CancelStage = "none"
	CancelStagePreAccept    CancelStage = "pre_accept"
	CancelStagePreEngine    CancelStage = "pre_engine"
	CancelStagePrefill      CancelStage = "prefill"
	CancelStageDecode       CancelStage = "decode"
	CancelStagePostTerminal CancelStage = "post_terminal"
	CancelStageOther        CancelStage = EnumOther
)

// Valid reports membership in the closed vocabulary ("" is absent, not valid).
func (c CancelStage) Valid() bool {
	switch c {
	case CancelStageNone, CancelStagePreAccept, CancelStagePreEngine, CancelStagePrefill,
		CancelStageDecode, CancelStagePostTerminal, CancelStageOther:
		return true
	}
	return false
}

// Fold returns the value unchanged when valid or absent, else "other".
func (c CancelStage) Fold() CancelStage { return foldEnum(c, CancelStageOther) }

// EngineFinishReason is why the engine stopped generating.
type EngineFinishReason string

const (
	EngineFinishStop         EngineFinishReason = "stop"
	EngineFinishLength       EngineFinishReason = "length"
	EngineFinishStopSequence EngineFinishReason = "stop_sequence"
	EngineFinishCancelled    EngineFinishReason = "cancelled"
	EngineFinishError        EngineFinishReason = "error"
	EngineFinishOther        EngineFinishReason = EnumOther
)

// Valid reports membership in the closed vocabulary ("" is absent, not valid).
func (r EngineFinishReason) Valid() bool {
	switch r {
	case EngineFinishStop, EngineFinishLength, EngineFinishStopSequence,
		EngineFinishCancelled, EngineFinishError, EngineFinishOther:
		return true
	}
	return false
}

// Fold returns the value unchanged when valid or absent, else "other".
func (r EngineFinishReason) Fold() EngineFinishReason { return foldEnum(r, EngineFinishOther) }

// MemoryPressureLevel is the OS memory-pressure level on BackendCapacity.telemetry.
type MemoryPressureLevel string

const (
	MemoryPressureNormal   MemoryPressureLevel = "normal"
	MemoryPressureWarning  MemoryPressureLevel = "warning"
	MemoryPressureCritical MemoryPressureLevel = "critical"
	MemoryPressureOther    MemoryPressureLevel = EnumOther
)

// Valid reports membership in the closed vocabulary ("" is absent, not valid).
func (l MemoryPressureLevel) Valid() bool {
	switch l {
	case MemoryPressureNormal, MemoryPressureWarning, MemoryPressureCritical, MemoryPressureOther:
		return true
	}
	return false
}

// Fold returns the value unchanged when valid or absent, else "other".
func (l MemoryPressureLevel) Fold() MemoryPressureLevel { return foldEnum(l, MemoryPressureOther) }

// foldEnum keeps "" (absent) and valid values; anything else becomes other.
func foldEnum[T interface {
	~string
	Valid() bool
}](v, other T) T {
	if v == "" || v.Valid() {
		return v
	}
	return other
}

// InferenceProfile is the typed decode target for the `profile` object.
// Offsets are microseconds from t0p = WS frame receipt on the provider's
// SuspendingClock; durations are microseconds; the engine sub-object is in
// nanoseconds from engine enqueue (DispatchTime domain). Never subtract
// across the two domains. wall_ms is the single, untrusted wall anchor.
type InferenceProfile struct {
	Schema *int   `json:"schema,omitempty"`
	WallMS *int64 `json:"wall_ms,omitempty"`

	// Offsets (µs from t0p).
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

	// Durations (µs).
	ToolConstraintUS   *int64 `json:"tool_constraint_us,omitempty"`
	VisionPrepUS       *int64 `json:"vision_prep_us,omitempty"`
	SSDStageUS         *int64 `json:"ssd_stage_us,omitempty"`
	KVReserveUS        *int64 `json:"kv_reserve_us,omitempty"`
	FlushUS            *int64 `json:"flush_us,omitempty"`
	SESignUS           *int64 `json:"se_sign_us,omitempty"`
	SleptUS            *int64 `json:"slept_us,omitempty"`
	ProjectedServiceUS *int64 `json:"projected_service_us,omitempty"`
	// Remaining first-content budget at the engine's VERDICT instant. Present
	// on admits AND on deadline_unreachable refusals (the provider stamps the
	// refusal's projection too), so its presence is not evidence the engine
	// admitted the request — key admission on engine_admitted_us alone.
	BudgetRemainingAtAdmitUS *int64 `json:"budget_remaining_at_admit_us,omitempty"`

	// Counts.
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

	// Bytes.
	BytesEmitted           *int64 `json:"bytes_emitted,omitempty"`
	KVBytesInUseAtAdmit    *int64 `json:"kv_bytes_in_use_at_admit,omitempty"`
	KVBytesCapacity        *int64 `json:"kv_bytes_capacity,omitempty"`
	MLXActiveBytesAtFinish *int64 `json:"mlx_active_bytes_at_finish,omitempty"`
	MLXPeakBytes           *int64 `json:"mlx_peak_bytes,omitempty"`

	// Booleans.
	UsageRecovered *bool `json:"usage_recovered,omitempty"`
	LoadCold       *bool `json:"load_cold,omitempty"`
	LoadParked     *bool `json:"load_parked,omitempty"`
	MTPActive      *bool `json:"mtp_active,omitempty"`
	LowPowerMode   *bool `json:"low_power_mode,omitempty"`

	// Closed enums.
	DeadlineMode DeadlineMode `json:"deadline_mode,omitempty"`
	ThermalState ThermalState `json:"thermal_state,omitempty"`
	CancelStage  CancelStage  `json:"cancel_stage,omitempty"`

	// Engine sub-object (slice 3 fills it; slice 2 may send it empty/absent).
	Engine *EngineProfile `json:"engine,omitempty"`
}

// EngineProfile is the engine's per-request timing and counters, nanoseconds
// from engine enqueue in the DispatchTime domain.
type EngineProfile struct {
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

	FinishReason EngineFinishReason `json:"finish_reason,omitempty"`
}

// SlotTelemetry is the optional per-slot sub-object on BackendSlotCapacity.
// Presence is the "new provider" sentinel; inside it an absent numeric reads
// as 0. MEASUREMENT ONLY: decoded, clamped (registry.clampBackendCapacity)
// and retained for fleet_snapshots; routing is not gated on any field.
type SlotTelemetry struct {
	QueuedPrefillTokens *int64   `json:"queued_prefill_tokens,omitempty"` // Σ prompt tokens of requests whose engine submit has not returned
	PartialPrefillRows  *int64   `json:"partial_prefill_rows,omitempty"`  // admitted rows with no first token yet
	PrefillTokensTotal  *int64   `json:"prefill_tokens_total,omitempty"`  // cumulative
	IsolatedPrefillTPS  *float64 `json:"isolated_prefill_tps,omitempty"`
	EWMAInitialized     *bool    `json:"ewma_initialized,omitempty"`
	PumpTasks           *int64   `json:"pump_tasks,omitempty"`
	MTPRoundsTotal      *int64   `json:"mtp_rounds_total,omitempty"`   // cumulative
	MTPProposedTotal    *int64   `json:"mtp_proposed_total,omitempty"` // cumulative
	MTPAcceptedTotal    *int64   `json:"mtp_accepted_total,omitempty"` // cumulative
	KVBytesInUse        *int64   `json:"kv_bytes_in_use,omitempty"`
	KVBytesCapacity     *int64   `json:"kv_bytes_capacity,omitempty"`
	EvalInFlightMS      *int64   `json:"eval_in_flight_ms,omitempty"`
	StepWallNSTotal     *int64   `json:"step_wall_ns_total,omitempty"` // cumulative; slice 3 producer
	DecodeRowsTotal     *int64   `json:"decode_rows_total,omitempty"`  // cumulative; slice 3 producer
}

// Clone returns a detached deep copy (nil-safe).
func (t *SlotTelemetry) Clone() *SlotTelemetry {
	if t == nil {
		return nil
	}
	return &SlotTelemetry{
		QueuedPrefillTokens: clonePtr(t.QueuedPrefillTokens),
		PartialPrefillRows:  clonePtr(t.PartialPrefillRows),
		PrefillTokensTotal:  clonePtr(t.PrefillTokensTotal),
		IsolatedPrefillTPS:  clonePtr(t.IsolatedPrefillTPS),
		EWMAInitialized:     clonePtr(t.EWMAInitialized),
		PumpTasks:           clonePtr(t.PumpTasks),
		MTPRoundsTotal:      clonePtr(t.MTPRoundsTotal),
		MTPProposedTotal:    clonePtr(t.MTPProposedTotal),
		MTPAcceptedTotal:    clonePtr(t.MTPAcceptedTotal),
		KVBytesInUse:        clonePtr(t.KVBytesInUse),
		KVBytesCapacity:     clonePtr(t.KVBytesCapacity),
		EvalInFlightMS:      clonePtr(t.EvalInFlightMS),
		StepWallNSTotal:     clonePtr(t.StepWallNSTotal),
		DecodeRowsTotal:     clonePtr(t.DecodeRowsTotal),
	}
}

// CapacityTelemetry is the optional machine-level sub-object on
// BackendCapacity. Same rules as SlotTelemetry.
type CapacityTelemetry struct {
	LowPowerMode        *bool               `json:"low_power_mode,omitempty"`
	MemoryPressureLevel MemoryPressureLevel `json:"memory_pressure_level,omitempty"`
	MLXNumResources     *int64              `json:"mlx_num_resources,omitempty"`
	InAdmission         *int64              `json:"in_admission,omitempty"`
	InflightTasks       *int64              `json:"inflight_tasks,omitempty"`
}

// Clone returns a detached deep copy (nil-safe).
func (t *CapacityTelemetry) Clone() *CapacityTelemetry {
	if t == nil {
		return nil
	}
	return &CapacityTelemetry{
		LowPowerMode:        clonePtr(t.LowPowerMode),
		MemoryPressureLevel: t.MemoryPressureLevel,
		MLXNumResources:     clonePtr(t.MLXNumResources),
		InAdmission:         clonePtr(t.InAdmission),
		InflightTasks:       clonePtr(t.InflightTasks),
	}
}

func clonePtr[T any](p *T) *T {
	if p == nil {
		return nil
	}
	v := *p
	return &v
}
