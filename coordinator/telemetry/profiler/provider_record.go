package profiler

import (
	"encoding/json"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

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
// this needs; the attempt supplies terminal usage for the consistency check.
//
// The typed columns, the transport estimate and the consistency flag are
// filled only from a VALID profile; a range/order-flagged profile keeps its
// clamped JSONB for forensics but never reaches the queryable columns.
func (b Builder) applyProviderProfile(rec *store.RequestProfileRecord, ap *registry.AttemptProfile, raw []byte) {
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
	b.incr("profiler.provider_profile", []string{"valid:" + strconv.FormatBool(valid), "reason:" + reasonTag})
	if enumFolded {
		b.incr("profiler.provider_profile", []string{"valid:" + strconv.FormatBool(valid), "reason:enum"})
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
