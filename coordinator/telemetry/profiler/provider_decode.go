package profiler

// Provider diagnostics are decoded into a separate stored allowlist.
// Unknown fields never persist; absent numerics stay absent and invalid values
// cannot populate typed timing columns. Decoder errors are never logged.

import (
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
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
		Schema: cloneProfileValue(w.Schema),
		WallMS: cloneProfileValue(w.WallMS),

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

		UsageRecovered: cloneProfileValue(w.UsageRecovered),
		LoadCold:       cloneProfileValue(w.LoadCold),
		LoadParked:     cloneProfileValue(w.LoadParked),
		MTPActive:      cloneProfileValue(w.MTPActive),
		LowPowerMode:   cloneProfileValue(w.LowPowerMode),

		DeadlineMode: w.DeadlineMode.Fold(),
		ThermalState: w.ThermalState.Fold(),
		CancelStage:  w.CancelStage.Fold(),
	}
	enumFolded = stored.DeadlineMode != w.DeadlineMode ||
		stored.ThermalState != w.ThermalState ||
		stored.CancelStage != w.CancelStage
	decision, decisionFolded := storeDeadlineDecision(w.DeadlineDecision, &b)
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
