package profile

// Builds the persisted store.RequestProfileRecord from an in-memory
// registry.RequestProfile / AttemptProfile. Finalization only enqueues a job;
// the dedicated profile sink worker flattens it and encodes decision context,
// outside registry locks and off the reserve path.

import (
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Closed vocabularies persisted by the profiler. Provider-authored strings are
// folded onto these before they reach a row; unknown values become "other".
const (
	FinalStatusSuccess = "success"
	Other              = "other"

	ProviderProfileAbsent = "absent"
)

// foldChipFamily maps a provider-reported chip family to {m1,m2,m3,m4,m5,other}.
func FoldChipFamily(raw string) string {
	v := strings.ToLower(strings.TrimSpace(raw))
	switch v {
	case "m1", "m2", "m3", "m4", "m5":
		return v
	}
	if len(v) >= 2 && v[0] == 'm' && v[1] >= '1' && v[1] <= '9' {
		return v[:2]
	}
	return Other
}

// foldProviderVersion accepts semver-shaped versions only. The fold lives in
// the registry (registry.ProviderVersionFold) because the fleet sampler
// persists the same bounded value on fleet_snapshots.provider_version.
func FoldProviderVersion(raw string) string {
	return registry.ProviderVersionFold(raw)
}

func USPtr(v int64) *int64 {
	if v <= 0 {
		return nil
	}
	return &v
}

func BoolPtr(b bool) *bool { return &b }

// buildProfileRecord flattens one attempt into a store row.
func (s *Profiler) BuildRecord(rp *registry.RequestProfile, ap *registry.AttemptProfile) *store.RequestProfileRecord {
	if rp == nil || ap == nil {
		return nil
	}
	finalStatus, errorReason, terminalCause, providerOutcome, clientOutcome := ap.Outcome()
	if finalStatus == "" {
		// No phase-aware classifier wrote a status (e.g. consumer gone before
		// the provider terminal): derive a closed value from the terminal.
		switch providerOutcome {
		case "completed":
			finalStatus = FinalStatusSuccess
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

		AuthDoneUS:            USPtr(rp.AuthDoneUS),
		RatelimitDoneUS:       USPtr(rp.RatelimitDoneUS),
		SealedOpenUS:          USPtr(rp.SealedOpenUS),
		HandlerEntryUS:        USPtr(rp.HandlerEntryUS.Load()),
		ParsedUS:              USPtr(rp.ParsedUS.Load()),
		ReservedUS:            USPtr(rp.ReservedUS.Load()),
		MediaFetchedUS:        USPtr(rp.MediaFetchedUS.Load()),
		PreflightDoneUS:       USPtr(rp.PreflightDoneUS.Load()),
		PlanDoneUS:            USPtr(rp.PlanDoneUS.Load()),
		AttemptStartUS:        USPtr(ap.AttemptStartUS.Load()),
		ReserveLockAcquiredUS: USPtr(ap.ReserveLockAcquiredUS.Load()),
		ReserveDoneUS:         USPtr(ap.ReserveDoneUS.Load()),
		QueuedUS:              USPtr(ap.QueuedUS.Load()),
		DequeuedUS:            USPtr(ap.DequeuedUS.Load()),
		TopupDoneUS:           USPtr(ap.TopupDoneUS.Load()),
		EncryptedUS:           USPtr(ap.EncryptedUS.Load()),
		WriteSubmittedUS:      USPtr(ap.WriteSubmittedUS.Load()),
		WriteDequeuedUS:       USPtr(ap.WriteDequeuedUS.Load()),
		WriteDoneUS:           USPtr(ap.WriteDoneUS.Load()),
		AcceptedUS:            USPtr(ap.AcceptedUS.Load()),
		FirstChunkIngressUS:   USPtr(ap.FirstChunkIngressUS.Load()),
		FirstChunkDequeuedUS:  USPtr(ap.FirstChunkDequeuedUS.Load()),
		FirstContentIngressUS: USPtr(ap.FirstContentIngressUS.Load()),
		FirstContentUS:        USPtr(ap.FirstContentUS.Load()),
		HeadersWrittenUS:      USPtr(rp.HeadersWrittenUS.Load()),
		FirstFlushUS:          USPtr(rp.FirstFlushUS.Load()),
		LastFlushUS:           USPtr(rp.LastFlushUS.Load()),
		ClientGoneUS:          USPtr(rp.ClientGoneUS.Load()),
		CancelSentUS:          USPtr(ap.CancelSentUS.Load()),
		CompleteIngressUS:     USPtr(ap.CompleteIngressUS.Load()),
		DoneFlushedUS:         USPtr(rp.DoneFlushedUS.Load()),
		FinalizedUS:           USPtr(ap.FinalizedUS.Load()),
		SettleDBUS:            USPtr(ap.SettleDBUS.Load()),
		DBUS:                  USPtr(rp.DBUS.Load()),
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
		rec.Candidates, rec.GateRejections = DecisionJSON(d)
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
			rec.ShadowWouldShed = BoolPtr(d.ShadowWouldShed)
			rec.ShadowIdleAlternative = BoolPtr(d.ShadowIdleAlternativeExists)
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
	rec.ProviderVersion = FoldProviderVersion(ap.ProviderVersion)
	rec.ChipFamily = FoldChipFamily(ap.ChipFamily)
	rec.KVBackend = ap.KVBackend

	// Transport estimate: two coordinator stamps minus a provider duration.
	// Only computable once the provider profile (slice 2) reports total_us.
	raw, late := ap.ProviderProfileRaw()
	switch {
	case len(raw) > 0:
		s.ApplyProviderProfile(rec, ap, raw)
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
			rec.ProviderProfileInvalidReason = ProviderProfileAbsent
		}
	}
	rec.TimingAnomaly = profileTimingAnomaly(rec)
	return rec
}

// profileTimingAnomaly flags non-monotonic coordinator stamps (a retried
// attempt that re-stamped, a clock issue, or a bug). Never rejects the row.
func profileTimingAnomaly(rec *store.RequestProfileRecord) bool {
	order := []*int64{
		rec.HandlerEntryUS, rec.ParsedUS, rec.ReservedUS, rec.AttemptStartUS, rec.ReserveDoneUS,
		rec.EncryptedUS, rec.WriteSubmittedUS, rec.WriteDequeuedUS, rec.WriteDoneUS,
		rec.FirstChunkIngressUS, rec.FirstContentUS, rec.CompleteIngressUS,
	}
	var last int64
	for _, p := range order {
		if p == nil {
			continue
		}
		if *p < last {
			return true
		}
		last = *p
	}
	return false
}

// AlwaysRecord reports whether a record bypasses sampling.
func (p *Profiler) AlwaysRecord(rec *store.RequestProfileRecord) bool {
	if rec == nil {
		return false
	}
	if rec.FinalStatus != FinalStatusSuccess {
		return true
	}
	if rec.FirstContentUS != nil && *rec.FirstContentUS > profileSlowFirstContent.Microseconds() {
		return true
	}
	if rec.FinalizedUS != nil && *rec.FinalizedUS > profileSlowTotal.Microseconds() {
		return true
	}
	if rec.AttemptsTotal > 1 || rec.BackupLaunched || rec.TimingAnomaly || rec.ClientGonePhase != "" {
		return true
	}
	if !rec.ProviderProfileValid && rec.ProviderProfileInvalidReason != ProviderProfileAbsent {
		return true
	}
	return false
}
