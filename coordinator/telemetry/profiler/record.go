package profiler

// Record construction runs on the profile worker after attempt finalization.
// It observes lifecycle state without changing routing, settlement or output.

import (
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Builder flattens finalized attempts and validates provider diagnostics.
// Incr is the only output besides the returned record: bounded metric names
// and tags. It may be nil. The builder never logs or persists raw provider bytes.
type Builder struct{ Incr func(string, []string) }

func (b Builder) incr(name string, tags []string) {
	if b.Incr != nil {
		b.Incr(name, tags)
	}
}

// Closed vocabularies persisted by the profiler. Provider-authored strings are
// folded onto these before they reach a row; unknown values become "other".
const (
	profileOther = "other"

	providerProfileAbsent = "absent"
)

// foldChipFamily maps a provider-reported chip family to m1 through m9 or other.
func foldChipFamily(raw string) string {
	v := strings.ToLower(strings.TrimSpace(raw))
	switch v {
	case "m1", "m2", "m3", "m4", "m5":
		return v
	}
	if len(v) >= 2 && v[0] == 'm' && v[1] >= '1' && v[1] <= '9' {
		return v[:2]
	}
	return profileOther
}

// foldProviderVersion accepts semver-shaped versions only. The fold lives in
// the registry (registry.ProviderVersionFold) because the fleet sampler
// persists the same bounded value on fleet_snapshots.provider_version.
func foldProviderVersion(raw string) string {
	return registry.ProviderVersionFold(raw)
}

func usPtr(v int64) *int64 {
	if v <= 0 {
		return nil
	}
	return &v
}

func boolPtr(b bool) *bool { return &b }

// Build flattens one attempt into a store row.
func (b Builder) Build(rp *registry.RequestProfile, ap *registry.AttemptProfile) *store.RequestProfileRecord {
	if rp == nil || ap == nil {
		return nil
	}
	finalStatus, errorReason, terminalCause, providerOutcome, clientOutcome := ap.Outcome()
	if finalStatus == "" {
		// No phase-aware classifier wrote a status (e.g. consumer gone before
		// the provider terminal): derive a closed value from the terminal.
		switch providerOutcome {
		case "completed":
			finalStatus = finalStatusSuccess
		case "error", "no_terminal", "not_dispatched":
			finalStatus = providerOutcome
		}
	}
	rec := &store.RequestProfileRecord{
		CoordRequestID:        rp.CoordRequestID,
		RequestID:             ap.RequestID,
		Attempt:               ap.Attempt,
		BackupOf:              ap.BackupOf,
		Winning:               ap.Winning.Load(),
		Endpoint:              rp.Endpoint,
		Stream:                rp.Stream,
		Model:                 rp.Model,
		PublicModel:           rp.PublicModel,
		ProviderID:            ap.ProviderID,
		FinalStatus:           finalStatus,
		ErrorReason:           errorReason,
		TerminalCause:         terminalCause,
		ClientOutcome:         clientOutcome,
		ProviderOutcome:       providerOutcome,
		ClientGonePhase:       rp.ClientGonePhase(),
		FirstContentBudgetMs:  rp.FirstContentBudgetMs,
		AdmissionMode:         rp.AdmissionMode,
		EstimatedPromptTokens: rp.EstimatedPromptTokens,
		RequestedMaxTokens:    rp.RequestedMaxTokens,
		RequiresVision:        rp.RequiresVision,
		HasTools:              rp.HasTools,
		ReceivedAt:            rp.T0,

		AuthDoneUS:            usPtr(rp.AuthDoneUS),
		RatelimitDoneUS:       usPtr(rp.RatelimitDoneUS),
		SealedOpenUS:          usPtr(rp.SealedOpenUS),
		HandlerEntryUS:        usPtr(rp.HandlerEntryUS.Load()),
		ParsedUS:              usPtr(rp.ParsedUS.Load()),
		ReservedUS:            usPtr(rp.ReservedUS.Load()),
		MediaFetchedUS:        usPtr(rp.MediaFetchedUS.Load()),
		PreflightDoneUS:       usPtr(rp.PreflightDoneUS.Load()),
		PlanDoneUS:            usPtr(rp.PlanDoneUS.Load()),
		AttemptStartUS:        usPtr(ap.AttemptStartUS.Load()),
		ReserveLockAcquiredUS: usPtr(ap.ReserveLockAcquiredUS.Load()),
		ReserveDoneUS:         usPtr(ap.ReserveDoneUS.Load()),
		QueuedUS:              usPtr(ap.QueuedUS.Load()),
		DequeuedUS:            usPtr(ap.DequeuedUS.Load()),
		TopupDoneUS:           usPtr(ap.TopupDoneUS.Load()),
		EncryptedUS:           usPtr(ap.EncryptedUS.Load()),
		WriteSubmittedUS:      usPtr(ap.WriteSubmittedUS.Load()),
		WriteDequeuedUS:       usPtr(ap.WriteDequeuedUS.Load()),
		WriteDoneUS:           usPtr(ap.WriteDoneUS.Load()),
		AcceptedUS:            usPtr(ap.AcceptedUS.Load()),
		FirstChunkIngressUS:   usPtr(ap.FirstChunkIngressUS.Load()),
		FirstChunkDequeuedUS:  usPtr(ap.FirstChunkDequeuedUS.Load()),
		FirstContentIngressUS: usPtr(ap.FirstContentIngressUS.Load()),
		FirstContentUS:        usPtr(ap.FirstContentUS.Load()),
		HeadersWrittenUS:      usPtr(rp.HeadersWrittenUS.Load()),
		FirstFlushUS:          usPtr(rp.FirstFlushUS.Load()),
		LastFlushUS:           usPtr(rp.LastFlushUS.Load()),
		ClientGoneUS:          usPtr(rp.ClientGoneUS.Load()),
		CancelSentUS:          usPtr(ap.CancelSentUS.Load()),
		CompleteIngressUS:     usPtr(ap.CompleteIngressUS.Load()),
		DoneFlushedUS:         usPtr(rp.DoneFlushedUS.Load()),
		FinalizedUS:           usPtr(ap.FinalizedUS.Load()),
		SettleDBUS:            usPtr(ap.SettleDBUS.Load()),
		DBUS:                  usPtr(rp.DBUS.Load()),
		DBCalls:               int(rp.DBCalls.Load()),

		BodyBytes:          rp.BodyBytes,
		SealedBodyBytes:    rp.SealedBodyBytes,
		AuthKind:           rp.AuthKind,
		AuthDBRead:         rp.AuthDBRead,
		ReserveMode:        rp.ReserveMode,
		MediaItems:         rp.MediaItems,
		MediaBytes:         rp.MediaBytes,
		PreflightOutcome:   rp.PreflightOutcome,
		PlanOutcome:        rp.PlanOutcome,
		ChunksIn:           int(ap.ChunksIn.Load()),
		ChunksOut:          int(rp.ChunksOut.Load()),
		BytesOut:           rp.BytesOut.Load(),
		DecryptUSTotal:     ap.DecryptUSTotal.Load(),
		MaxChunkGapUS:      rp.MaxChunkGapUS.Load(),
		HeldPreambleChunks: rp.HeldPreambleChunks(),
		ClientWriteErr:     rp.ClientWriteErr.Load(),
		AttemptsTotal:      rp.DispatchedAttempts(),
		BackupLaunched:     ap.BackupLaunched.Load(),
		BackupWon:          ap.BackupWon.Load(),
		PreflightUS:        rp.PreflightUS,
		CreatedAt:          time.Now(),
	}
	rec.FailedAttempts, rec.FailedAttemptsUS = rp.FailedAttempts()

	mode, bypass, ceiling, budget := ap.PredictionObservation()
	if mode != "" {
		rec.AdmissionMode = mode
	}
	rec.PredictiveBypass = string(bypass)
	rec.ReservationTTFTCeilingMs = ceiling
	rec.DispatchBudgetMs = budget
	if ap.DecisionSet {
		d := ap.Decision
		rec.CandidateSetSize = d.CandidateSetSize
		rec.Scanned = d.Scanned
		rec.Candidates, rec.GateRejections = decisionJSON(d)
		if d.RunnerUp.Present {
			rec.RunnerUpProviderID = d.RunnerUp.ProviderID
			rec.RunnerUpCostMs = d.RunnerUp.CostMs
		}
		rec.NearTiePoolSize = d.NearTiePoolSize
		rec.SelectionPath = d.SelectionPath.String()
		if d.BestIdle.Present {
			rec.BestIdleProviderID = d.BestIdle.ProviderID
			rec.BestIdleTTFTMs = d.BestIdle.TTFTMs
		}
		rec.PredictedTTFTMs = d.TTFTMs
		rec.RawTTFTMs = d.RawTTFTMs
		rec.PredictedDecodeTPS = d.PredictedDecodeTPS
		rec.SnapshotAgeMs = d.SnapshotAgeMs
		rec.PendingForModel = d.PendingForModel
		rec.TotalPending = d.TotalPending
		rec.CapacityRateMs = d.CapacityRateMs
		rec.CacheDiscountMs = d.CacheDiscountMs
		if d.ShadowEvaluated {
			rec.ShadowWouldShed = boolPtr(d.ShadowWouldShed)
			rec.ShadowIdleAlternative = boolPtr(d.ShadowIdleAlternativeExists)
		}
		rec.LockWaitUS = d.LockWaitUS
		rec.ScanUS = d.ScanUS
		rec.AdmitUS = d.AdmitUS
		rec.TTFTCalibrationRatio = d.TTFTCalibrationRatio
		rec.PrefillDecodeRatio = d.PrefillDecodeRatio
		rec.QueuePositionAtEnqueue = d.QueuePosition
		rec.QueueDepthAtEnqueue = d.QueueDepth
		rec.DrainTrigger = d.DrainTrigger
	}

	// Provider snapshot fields folded at the profiler boundary (never verbatim).
	rec.ProviderVersion = foldProviderVersion(ap.ProviderVersion)
	rec.ChipFamily = foldChipFamily(ap.ChipFamily)
	rec.KVBackend = ap.KVBackend

	// Transport estimate: two coordinator stamps minus a provider duration.
	// Only computable once the provider profile (slice 2) reports total_us.
	raw, late := ap.ProviderProfileRaw()
	switch {
	case len(raw) > 0:
		b.applyProviderProfile(rec, ap, raw)
	case late:
		rec.ProviderProfileValid = false
		rec.ProviderProfileInvalidReason = "late"
	default:
		rec.ProviderProfileValid = false
		switch ap.ProviderProfileIngressStatus() {
		case registry.ProviderProfileTooLarge:
			rec.ProviderProfileInvalidReason = "size"
		case registry.ProviderProfileDuplicate:
			rec.ProviderProfileInvalidReason = "duplicate"
		default:
			rec.ProviderProfileInvalidReason = providerProfileAbsent
		}
	}
	rec.TimingAnomaly = profileTimingAnomaly(rec)
	return rec
}
