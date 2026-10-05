package profile

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
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Contract ranges (CONTRACT-WIRE.md §1).
const (
	MaxProfileUS       int64 = 3_600_000_000     // 1 h in µs
	MaxProfileNS       int64 = 3_600_000_000_000 // 1 h in ns
	MaxProfileCount    int   = 1_000_000_000
	MaxProfileBytes    int64 = 1 << 48
	MaxProfileWallSkew       = 24 * time.Hour
)

// Bounded provider_profile_invalid_reason values produced here. The record
// builder adds "late" and providerProfileAbsent; "duplicate" and "no_terminal"
// are accounted by the ingress site.
const (
	InvalidSize   = "size"
	InvalidDecode = "decode"
	InvalidSchema = "schema"
	InvalidRange  = "range"
	InvalidOrder  = "order"
)

// profileBounds clamps wire numerics into contract range while recording
// whether any value had to be clamped. Every method returns a NEW pointer so
// the stored struct never aliases the wire struct; nil stays nil (absent).
type Bounds struct{ violated bool }

func (b *Bounds) Violated() bool { return b.violated }

func (b *Bounds) i64(p *int64, limit int64) *int64 {
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

func (b *Bounds) us(p *int64) *int64    { return b.i64(p, MaxProfileUS) }
func (b *Bounds) ns(p *int64) *int64    { return b.i64(p, MaxProfileNS) }
func (b *Bounds) bytes(p *int64) *int64 { return b.i64(p, MaxProfileBytes) }

func (b *Bounds) count(p *int) *int {
	if p == nil {
		return nil
	}
	v := *p
	switch {
	case v < 0:
		v, b.violated = 0, true
	case v > MaxProfileCount:
		v, b.violated = MaxProfileCount, true
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
func DecodeInferenceProfile(raw []byte, receivedAt time.Time) (stored *StoredInferenceProfile, valid bool, reason string, enumFolded bool) {
	if len(raw) > protocol.MaxInferenceProfileBytes {
		return nil, false, InvalidSize, false
	}
	var w protocol.InferenceProfile
	if err := json.Unmarshal(raw, &w); err != nil {
		// err can quote provider-controlled bytes: deliberately not logged.
		return nil, false, InvalidDecode, false
	}
	if w.Schema == nil || *w.Schema != protocol.InferenceProfileSchema {
		return nil, false, InvalidSchema, false
	}

	var b Bounds
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
	decision, decisionFolded := StoreDeadlineDecision(w.DeadlineDecision, &b)
	stored.DeadlineDecision = decision
	enumFolded = enumFolded || decisionFolded

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
		if skew > MaxProfileWallSkew || skew < -MaxProfileWallSkew {
			b.violated = true
		}
	}
	if b.Violated() {
		return stored, false, InvalidRange, enumFolded
	}
	if !storedProfileOrdered(stored) {
		return stored, false, InvalidOrder, enumFolded
	}
	return stored, true, "", enumFolded
}

// storedProfileOrdered checks the contract's monotonicity invariants over the
// PRESENT stamps. It runs after the range check, so values equal the wire
// values here.
func storedProfileOrdered(p *StoredInferenceProfile) bool {
	if !storedDeadlineDecisionOrdered(p) {
		return false
	}
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
