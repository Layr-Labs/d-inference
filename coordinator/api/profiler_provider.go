package api

// Provider-reported profile ingestion (system profiler, slice 2).
//
// The `profile` object arrives on inference_complete / inference_error as raw
// bytes (protocol.InferenceCompleteMessage.Profile). The WS read loop only
// length-checks and retains them (registry.AttemptProfile.SetProviderProfileRaw);
// everything below runs on the profile sink path, after the terminal has been
// fully processed, and can only ever set the provider_profile* columns and one
// DD counter. Nothing here influences routing, health, billing, deadlines or
// client output.
//
// Confidentiality boundary: the raw bytes are never logged (a decoder error
// may quote provider-controlled values) and never stored. What is persisted is
// StoredInferenceProfile, a separate struct built field-by-field from the
// typed decode: pointer numerics clamped into contract range and closed enums
// folded to "other". TestStoredInferenceProfileHasNoFreeStrings forbids any
// free-form string from ever being added to it.

import (
	"encoding/json"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Contract ranges (CONTRACT-WIRE.md §1).
const (
	maxProfileUS       int64 = 3_600_000_000     // 1 h in µs
	maxProfileNS       int64 = 3_600_000_000_000 // 1 h in ns
	maxProfileCount    int   = 1_000_000_000
	maxProfileBytes    int64 = 1 << 48
	maxProfileWallSkew       = 24 * time.Hour
)

// Bounded provider_profile_invalid_reason values produced here. The record
// builder adds "late" and providerProfileAbsent; "duplicate" and "no_terminal"
// are accounted by the ingress site.
const (
	profileInvalidSize   = "size"
	profileInvalidDecode = "decode"
	profileInvalidSchema = "schema"
	profileInvalidRange  = "range"
	profileInvalidOrder  = "order"
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

// profileBounds clamps wire numerics into contract range while recording
// whether any value had to be clamped. Every method returns a NEW pointer so
// the stored struct never aliases the wire struct; nil stays nil (absent).
type profileBounds struct{ violated bool }

func (b *profileBounds) i64(p *int64, limit int64) *int64 {
	if p == nil {
		return nil
	}
	v := *p
	switch {
	case v < 0:
		v, b.violated = 0, true
	case v > limit:
		v, b.violated = limit, true
	}
	return &v
}

func (b *profileBounds) us(p *int64) *int64    { return b.i64(p, maxProfileUS) }
func (b *profileBounds) ns(p *int64) *int64    { return b.i64(p, maxProfileNS) }
func (b *profileBounds) bytes(p *int64) *int64 { return b.i64(p, maxProfileBytes) }

func (b *profileBounds) count(p *int) *int {
	if p == nil {
		return nil
	}
	v := *p
	switch {
	case v < 0:
		v, b.violated = 0, true
	case v > maxProfileCount:
		v, b.violated = maxProfileCount, true
	}
	return &v
}

func cloneBoolPtr(p *bool) *bool {
	if p == nil {
		return nil
	}
	v := *p
	return &v
}

func cloneInt64Ptr(p *int64) *int64 {
	if p == nil {
		return nil
	}
	v := *p
	return &v
}

func cloneIntPtr(p *int) *int {
	if p == nil {
		return nil
	}
	v := *p
	return &v
}

// nonDecreasing reports whether the PRESENT values are in non-decreasing
// order; absent (nil) stamps are skipped, so a partial profile from an early
// terminal still validates.
func nonDecreasing[T ~int | ~int64](vals ...*T) bool {
	var last T
	have := false
	for _, p := range vals {
		if p == nil {
			continue
		}
		if have && *p < last {
			return false
		}
		last, have = *p, true
	}
	return true
}

// decodeInferenceProfile validates raw provider profile bytes and builds the
// persisted struct. It never logs. Outcomes:
//
//   - size / decode / schema: stored == nil, valid == false.
//   - range: every numeric was clamped into contract range (or wall_ms is
//     more than 24 h from receivedAt); stored is returned for forensics with
//     valid == false — the typed hot columns are NOT filled from it.
//   - order: a monotonicity invariant over PRESENT stamps failed; same
//     handling as range.
//   - otherwise valid == true. Unknown enum values fold to "other" and set
//     enumFolded; that keeps the record valid (mixed-fleet tolerance).
func decodeInferenceProfile(raw []byte, receivedAt time.Time) (stored *StoredInferenceProfile, valid bool, reason string, enumFolded bool) {
	if len(raw) > protocol.MaxInferenceProfileBytes {
		return nil, false, profileInvalidSize, false
	}
	var w protocol.InferenceProfile
	if err := json.Unmarshal(raw, &w); err != nil {
		// err can quote provider-controlled bytes: deliberately not logged.
		return nil, false, profileInvalidDecode, false
	}
	if w.Schema == nil || *w.Schema != protocol.InferenceProfileSchema {
		return nil, false, profileInvalidSchema, false
	}

	var b profileBounds
	stored = &StoredInferenceProfile{
		Schema: cloneIntPtr(w.Schema),
		WallMS: cloneInt64Ptr(w.WallMS),

		DequeuedUS:        b.us(w.DequeuedUS),
		DecryptedUS:       b.us(w.DecryptedUS),
		ParsedUS:          b.us(w.ParsedUS),
		AdmissionUS:       b.us(w.AdmissionUS),
		AcceptedSentUS:    b.us(w.AcceptedSentUS),
		LoadWaitStartUS:   b.us(w.LoadWaitStartUS),
		LoadWaitEndUS:     b.us(w.LoadWaitEndUS),
		TaskSpawnedUS:     b.us(w.TaskSpawnedUS),
		PromptPrepStartUS: b.us(w.PromptPrepStartUS),
		PromptPrepEndUS:   b.us(w.PromptPrepEndUS),
		EngineSubmitUS:    b.us(w.EngineSubmitUS),
		EngineAdmittedUS:  b.us(w.EngineAdmittedUS),
		FirstDeltaUS:      b.us(w.FirstDeltaUS),
		FirstFrameUS:      b.us(w.FirstFrameUS),
		LastDeltaUS:       b.us(w.LastDeltaUS),
		TerminalBuiltUS:   b.us(w.TerminalBuiltUS),
		TerminalSentUS:    b.us(w.TerminalSentUS),
		CancelReceivedUS:  b.us(w.CancelReceivedUS),
		CancelAbortedUS:   b.us(w.CancelAbortedUS),
		TotalUS:           b.us(w.TotalUS),

		ToolConstraintUS:         b.us(w.ToolConstraintUS),
		VisionPrepUS:             b.us(w.VisionPrepUS),
		SSDStageUS:               b.us(w.SSDStageUS),
		KVReserveUS:              b.us(w.KVReserveUS),
		FlushUS:                  b.us(w.FlushUS),
		SESignUS:                 b.us(w.SESignUS),
		SleptUS:                  b.us(w.SleptUS),
		ProjectedServiceUS:       b.us(w.ProjectedServiceUS),
		BudgetRemainingAtAdmitUS: b.us(w.BudgetRemainingAtAdmitUS),

		PromptTokens:               b.count(w.PromptTokens),
		FramesEmitted:              b.count(w.FramesEmitted),
		RunningAtAdmit:             b.count(w.RunningAtAdmit),
		WaitingAtAdmit:             b.count(w.WaitingAtAdmit),
		QueuedPrefillTokensAtAdmit: b.count(w.QueuedPrefillTokensAtAdmit),
		StepsAtSubmit:              b.count(w.StepsAtSubmit),
		StepsAtFinish:              b.count(w.StepsAtFinish),
		ProjectedPrefillTokens:     b.count(w.ProjectedPrefillTokens),
		ProjectedDecodeTokens:      b.count(w.ProjectedDecodeTokens),
		PartialPrefillCap:          b.count(w.PartialPrefillCap),
		TokensAfterCancel:          b.count(w.TokensAfterCancel),

		BytesEmitted:           b.bytes(w.BytesEmitted),
		KVBytesInUseAtAdmit:    b.bytes(w.KVBytesInUseAtAdmit),
		KVBytesCapacity:        b.bytes(w.KVBytesCapacity),
		MLXActiveBytesAtFinish: b.bytes(w.MLXActiveBytesAtFinish),
		MLXPeakBytes:           b.bytes(w.MLXPeakBytes),

		UsageRecovered: cloneBoolPtr(w.UsageRecovered),
		LoadCold:       cloneBoolPtr(w.LoadCold),
		LoadParked:     cloneBoolPtr(w.LoadParked),
		MTPActive:      cloneBoolPtr(w.MTPActive),
		LowPowerMode:   cloneBoolPtr(w.LowPowerMode),

		DeadlineMode: w.DeadlineMode.Fold(),
		ThermalState: w.ThermalState.Fold(),
		CancelStage:  w.CancelStage.Fold(),
	}
	enumFolded = stored.DeadlineMode != w.DeadlineMode ||
		stored.ThermalState != w.ThermalState ||
		stored.CancelStage != w.CancelStage

	if e := w.Engine; e != nil {
		stored.Engine = &StoredEngineProfile{
			AdmittedNS:           b.ns(e.AdmittedNS),
			KVAllocatedNS:        b.ns(e.KVAllocatedNS),
			PrefillFirstLaunchNS: b.ns(e.PrefillFirstLaunchNS),
			PromptComputedNS:     b.ns(e.PromptComputedNS),
			FirstTokenNS:         b.ns(e.FirstTokenNS),
			FinishedNS:           b.ns(e.FinishedNS),

			Readmissions:     b.count(e.Readmissions),
			Preemptions:      b.count(e.Preemptions),
			CapacityRequeues: b.count(e.CapacityRequeues),

			PrefillChunks:         b.count(e.PrefillChunks),
			PackedPrefillChunks:   b.count(e.PackedPrefillChunks),
			VisionChunks:          b.count(e.VisionChunks),
			SoloStripeChunks:      b.count(e.SoloStripeChunks),
			PrefillChunkTokensMax: b.count(e.PrefillChunkTokensMax),

			DecodeSteps:        b.count(e.DecodeSteps),
			ChainedDecodeSteps: b.count(e.ChainedDecodeSteps),
			BatchRowsSum:       b.count(e.BatchRowsSum),
			BatchRowsMin:       b.count(e.BatchRowsMin),
			BatchRowsMax:       b.count(e.BatchRowsMax),

			StepLatencyNSSum: b.ns(e.StepLatencyNSSum),
			StepLatencyNSMax: b.ns(e.StepLatencyNSMax),

			MTPRounds:   b.count(e.MTPRounds),
			MTPProposed: b.count(e.MTPProposed),
			MTPAccepted: b.count(e.MTPAccepted),

			PausedNS:          b.ns(e.PausedNS),
			PauseCount:        b.count(e.PauseCount),
			DetokDelayFirstNS: b.ns(e.DetokDelayFirstNS),
			PrefixLookupNS:    b.ns(e.PrefixLookupNS),
			PrefixAdoptionNS:  b.ns(e.PrefixAdoptionNS),

			FinishReason: e.FinishReason.Fold(),
		}
		enumFolded = enumFolded || stored.Engine.FinishReason != e.FinishReason
	}

	if w.WallMS != nil {
		skew := time.UnixMilli(*w.WallMS).Sub(receivedAt)
		if skew > maxProfileWallSkew || skew < -maxProfileWallSkew {
			b.violated = true
		}
	}
	if b.violated {
		return stored, false, profileInvalidRange, enumFolded
	}
	if !storedProfileOrdered(stored) {
		return stored, false, profileInvalidOrder, enumFolded
	}
	return stored, true, "", enumFolded
}

// storedProfileOrdered checks the contract's monotonicity invariants over the
// PRESENT stamps. It runs after the range check, so values equal the wire
// values here.
func storedProfileOrdered(p *StoredInferenceProfile) bool {
	if !nonDecreasing(p.DequeuedUS, p.DecryptedUS, p.ParsedUS, p.AdmissionUS,
		p.EngineSubmitUS, p.EngineAdmittedUS, p.FirstDeltaUS, p.LastDeltaUS,
		p.TerminalBuiltUS, p.TerminalSentUS, p.TotalUS) {
		return false
	}
	if !nonDecreasing(p.LoadWaitStartUS, p.LoadWaitEndUS) ||
		!nonDecreasing(p.PromptPrepStartUS, p.PromptPrepEndUS) ||
		!nonDecreasing(p.CancelReceivedUS, p.CancelAbortedUS) ||
		!nonDecreasing(p.StepsAtSubmit, p.StepsAtFinish) {
		return false
	}
	e := p.Engine
	if e == nil {
		return true
	}
	return nonDecreasing(e.AdmittedNS, e.KVAllocatedNS, e.PrefillFirstLaunchNS,
		e.PromptComputedNS, e.FirstTokenNS, e.FinishedNS) &&
		nonDecreasing(e.MTPAccepted, e.MTPProposed) &&
		nonDecreasing(e.BatchRowsMin, e.BatchRowsMax) &&
		nonDecreasing(e.StepLatencyNSMax, e.StepLatencyNSSum)
}

// spanUS returns end − start when both are present (nil otherwise). Order was
// already validated, so the result is never negative on a valid profile.
func spanUS(start, end *int64) *int64 {
	if start == nil || end == nil {
		return nil
	}
	v := *end - *start
	return &v
}

// applyProviderProfile decodes and validates the retained raw provider
// profile into the typed hot columns and the long-tail JSONB. It runs on the
// profile sink path, never on the WS read loop. rec already carries the
// coordinator stamps (WriteDoneUS, CompleteIngressUS, ChunksIn, ReceivedAt)
// this needs; the AttemptProfile is not consulted.
//
// The typed columns, the transport estimate and the consistency flag are
// filled only from a VALID profile; a range/order-flagged profile keeps its
// clamped JSONB for forensics but never reaches the queryable columns.
func (s *Server) applyProviderProfile(rec *store.RequestProfileRecord, ap *registry.AttemptProfile, raw []byte) {
	if rec == nil {
		return
	}
	receivedAt := rec.ReceivedAt
	if receivedAt.IsZero() {
		receivedAt = time.Now()
	}
	stored, valid, reason, enumFolded := decodeInferenceProfile(raw, receivedAt)
	rec.ProviderProfileValid = valid
	rec.ProviderProfileInvalidReason = reason

	// The only telemetry derived from the profile: bounded tags, no values.
	reasonTag := reason
	if valid {
		reasonTag = "none"
	}
	s.ddIncr("profiler.provider_profile", []string{"valid:" + strconv.FormatBool(valid), "reason:" + reasonTag})
	if enumFolded {
		s.ddIncr("profiler.provider_profile", []string{"valid:" + strconv.FormatBool(valid), "reason:enum"})
	}
	if stored == nil {
		return
	}
	if encoded, err := json.Marshal(stored); err == nil {
		rec.ProviderProfile = encoded // the STORED struct, never the raw bytes
	}
	if !valid {
		return
	}

	rec.ProvTotalUS = cloneInt64Ptr(stored.TotalUS)
	rec.ProvFirstDeltaUS = cloneInt64Ptr(stored.FirstDeltaUS)
	rec.ProvEngineSubmitUS = cloneInt64Ptr(stored.EngineSubmitUS)
	rec.ProvEngineAdmittedUS = cloneInt64Ptr(stored.EngineAdmittedUS)
	rec.ProvPromptPrepUS = spanUS(stored.PromptPrepStartUS, stored.PromptPrepEndUS)
	rec.ProvLoadWaitUS = spanUS(stored.LoadWaitStartUS, stored.LoadWaitEndUS)
	rec.ProvLoadCold = cloneBoolPtr(stored.LoadCold)
	rec.ProvRunningAtAdmit = cloneIntPtr(stored.RunningAtAdmit)
	rec.ProvWaitingAtAdmit = cloneIntPtr(stored.WaitingAtAdmit)
	rec.ProvKVBytesInUseAtAdmit = cloneInt64Ptr(stored.KVBytesInUseAtAdmit)
	rec.ProvCancelStage = string(stored.CancelStage)
	if e := stored.Engine; e != nil {
		rec.EngQueueWaitNS = cloneInt64Ptr(e.AdmittedNS)
		rec.EngFirstTokenNS = cloneInt64Ptr(e.FirstTokenNS)
		rec.EngPromptComputedNS = cloneInt64Ptr(e.PromptComputedNS)
		rec.EngPrefillChunks = cloneIntPtr(e.PrefillChunks)
		rec.EngDecodeSteps = cloneIntPtr(e.DecodeSteps)
		rec.EngMTPAccepted = cloneIntPtr(e.MTPAccepted)
		rec.EngFinishReason = string(e.FinishReason)
	}
	rec.SleptUS = cloneInt64Ptr(stored.SleptUS)

	// Consistency flag (never invalidates). Two checks, each evaluated
	// independently and only when both of its inputs are present:
	//   - frames: the provider's frames_emitted against the chunks the read
	//     loop actually counted for this attempt;
	//   - prompt tokens: the profile's prompt_tokens against the usage on the
	//     terminal (recorded at ingress, outside the billing gate).
	// The flag is false when any present check fails, true when at least one
	// check ran and every present check passed, and NULL when nothing could be
	// checked — so an error terminal without frames_emitted is still judged on
	// its prompt tokens, and a completion without recorded terminal usage on
	// its frames alone.
	checked, consistent := false, true
	if stored.FramesEmitted != nil {
		checked = true
		if *stored.FramesEmitted != rec.ChunksIn {
			consistent = false
		}
	}
	if prompt, _, ok := ap.TerminalUsage(); ok && stored.PromptTokens != nil {
		checked = true
		if *stored.PromptTokens != prompt {
			consistent = false
		}
	}
	if checked {
		rec.ProviderProfileConsistent = boolPtr(consistent)
	}

	// Transport estimate: coordinator write-done → complete-ingress minus the
	// provider's own total. Non-provider time incl. both network legs, reader
	// wake and slept_us. Never subtracts across clock domains: the two
	// coordinator stamps share t0, total_us is a provider-local duration.
	if stored.TotalUS != nil && rec.CompleteIngressUS != nil && rec.WriteDoneUS != nil {
		v := (*rec.CompleteIngressUS - *rec.WriteDoneUS) - *stored.TotalUS
		rec.TransportEstUS = &v
	}
}

// retainProviderProfile hands the raw provider profile bytes to the attempt
// (size check only; decode + validation run on the profile sink worker) and
// counts the outcomes that never reach a row.
func (s *Server) retainProviderProfile(ap *registry.AttemptProfile, raw []byte) {
	if ap == nil || !s.profilerEnabled() {
		return
	}
	switch ap.SetProviderProfileRaw(raw) {
	case registry.ProviderProfileTooLarge:
		s.ddIncr("profiler.provider_profile", []string{"valid:false", "reason:size"})
	case registry.ProviderProfileDuplicate:
		s.ddIncr("profiler.provider_profile", []string{"valid:false", "reason:duplicate"})
	case registry.ProviderProfileLate:
		s.ddIncr("profiler.provider_profile", []string{"valid:false", "reason:late"})
	}
}
