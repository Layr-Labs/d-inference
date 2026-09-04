package api

// Builds the persisted store.RequestProfileRecord from an in-memory
// registry.RequestProfile / AttemptProfile. Runs on whichever goroutine
// finalized the attempt (never under any registry lock) and only enqueues onto
// the profile sink; all JSON encoding of the decision context happens here,
// off the reserve path.

import (
	"encoding/json"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Closed vocabularies persisted by the profiler. Provider-authored strings are
// folded onto these before they reach a row; unknown values become "other".
const (
	profileOther = "other"

	providerProfileAbsent = "absent"
)

// foldChipFamily maps a provider-reported chip family to {m1,m2,m3,m4,m5,other}.
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

// foldThermalState maps to {nominal,fair,serious,critical,other}.
func foldThermalState(raw string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "nominal", "fair", "serious", "critical":
		return strings.ToLower(strings.TrimSpace(raw))
	case "":
		return ""
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

// candidateJSON is the persisted shape of one candidate summary.
type candidateJSON struct {
	ProviderID            string  `json:"provider_id"`
	CostMs                float64 `json:"cost_ms"`
	StateMs               float64 `json:"state_ms"`
	QueueMs               float64 `json:"queue_ms"`
	PendingMs             float64 `json:"pending_ms"`
	BacklogMs             float64 `json:"backlog_ms"`
	ThisReqMs             float64 `json:"this_req_ms"`
	HealthMs              float64 `json:"health_ms"`
	CapacityRateMs        float64 `json:"capacity_rate_ms"`
	CacheDiscountMs       float64 `json:"cache_discount_ms"`
	TTFTMs                float64 `json:"ttft_ms"`
	EffectiveTPS          float64 `json:"effective_tps"`
	EffectiveQueue        int32   `json:"effective_queue"`
	TotalPending          int32   `json:"total_pending"`
	BackendRunning        int32   `json:"backend_running"`
	BackendWaiting        int32   `json:"backend_waiting"`
	ActiveTokenBudgetUsed int64   `json:"active_token_budget_used"`
	ActiveTokenBudgetMax  int64   `json:"active_token_budget_max"`
	QueuedPrefillTokens   int64   `json:"queued_prefill_tokens"`
	SlotState             string  `json:"slot_state"`
	HBAgeMs               int32   `json:"hb_age_ms"`
}

func candidateFromSummary(c registry.CandidateSummary) candidateJSON {
	return candidateJSON{
		ProviderID: c.ProviderID, CostMs: c.CostMs, StateMs: c.StateMs, QueueMs: c.QueueMs,
		PendingMs: c.PendingMs, BacklogMs: c.BacklogMs, ThisReqMs: c.ThisReqMs, HealthMs: c.HealthMs,
		CapacityRateMs: c.CapacityRateMs, CacheDiscountMs: c.CacheDiscountMs, TTFTMs: c.TTFTMs,
		EffectiveTPS: c.EffectiveTPS, EffectiveQueue: c.EffectiveQueue, TotalPending: c.TotalPending,
		BackendRunning: c.BackendRunning, BackendWaiting: c.BackendWaiting,
		ActiveTokenBudgetUsed: c.ActiveTokenBudgetUsed, ActiveTokenBudgetMax: c.ActiveTokenBudgetMax,
		QueuedPrefillTokens: c.QueuedPrefillTokens, SlotState: string(c.SlotState), HBAgeMs: c.HBAgeMs,
	}
}

// decisionJSON encodes the routing context fields that are not flat columns.
func decisionJSON(d registry.RoutingDecision) (candidates, gateRejections json.RawMessage) {
	top := make([]candidateJSON, 0, len(d.Top))
	for _, c := range d.Top {
		if c.Present {
			top = append(top, candidateFromSummary(c))
		}
	}
	if len(top) > 0 {
		if b, err := json.Marshal(top); err == nil {
			candidates = b
		}
	}
	rejections := make(map[string]uint16, 8)
	for i, n := range d.GateRejections {
		if n > 0 {
			rejections[registry.GateReason(i).String()] = n
		}
	}
	if len(rejections) > 0 {
		if b, err := json.Marshal(rejections); err == nil {
			gateRejections = b
		}
	}
	return candidates, gateRejections
}

// buildProfileRecord flattens one attempt into a store row.
func (s *Server) buildProfileRecord(rp *registry.RequestProfile, ap *registry.AttemptProfile) *store.RequestProfileRecord {
	if rp == nil || ap == nil {
		return nil
	}
	finalStatus, errorReason, terminalCause, providerOutcome, clientOutcome := ap.Outcome()
	finalStatus = deriveFinalStatus(finalStatus, providerOutcome)
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
		s.applyProviderProfile(rec, ap, raw)
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

// deriveFinalStatus is the row's final_status: the classifier's value when
// one was written, else a closed value derived from the provider terminal
// (e.g. consumer gone before the terminal). Shared by the flattened record
// and the pre-flatten sampling predicate so the two can never disagree.
func deriveFinalStatus(finalStatus, providerOutcome string) string {
	if finalStatus != "" {
		return finalStatus
	}
	switch providerOutcome {
	case "completed":
		return finalStatusSuccess
	case "error", "no_terminal", "not_dispatched":
		return providerOutcome
	}
	return ""
}

// profileTimingAnomaly flags non-monotonic coordinator stamps (a retried
// attempt that re-stamped, a clock issue, or a bug). Never rejects the row.
func profileTimingAnomaly(rec *store.RequestProfileRecord) bool {
	order := []*int64{
		rec.HandlerEntryUS, rec.ParsedUS, rec.ReservedUS, rec.AttemptStartUS, rec.ReserveDoneUS,
		rec.EncryptedUS, rec.WriteSubmittedUS, rec.WriteDequeuedUS, rec.WriteDoneUS,
		rec.FirstChunkIngressUS, rec.FirstContentUS, rec.CompleteIngressUS,
	}
	values := make([]int64, len(order))
	for i, p := range order {
		if p != nil {
			values[i] = *p
		}
	}
	return stampsOutOfOrder(values)
}

// profileTimingAnomalyRaw is profileTimingAnomaly evaluated on the live
// stamps, in the same order, before the row is flattened (an unset stamp is
// 0 here and nil there — usPtr maps <= 0 to nil).
func profileTimingAnomalyRaw(rp *registry.RequestProfile, ap *registry.AttemptProfile) bool {
	return stampsOutOfOrder([]int64{
		rp.HandlerEntryUS.Load(), rp.ParsedUS.Load(), rp.ReservedUS.Load(), ap.AttemptStartUS.Load(), ap.ReserveDoneUS.Load(),
		ap.EncryptedUS.Load(), ap.WriteSubmittedUS.Load(), ap.WriteDequeuedUS.Load(), ap.WriteDoneUS.Load(),
		ap.FirstChunkIngressUS.Load(), ap.FirstContentUS.Load(), ap.CompleteIngressUS.Load(),
	})
}

// stampsOutOfOrder reports whether the set (> 0) stamps are non-monotonic.
func stampsOutOfOrder(values []int64) bool {
	var last int64
	for _, v := range values {
		if v <= 0 {
			continue
		}
		if v < last {
			return true
		}
		last = v
	}
	return false
}

// shouldRecord decides, BEFORE the row is flattened, whether an attempt is
// persisted: the deterministic per-request sample, or one of the
// always-record predicates evaluated on the live profile. ~90% of clean
// successes are sampled out at the default rate; they no longer pay
// buildProfileRecord (~150 field copies, two decision JSON marshals) on the
// sink worker only to be discarded.
func (p *profiler) shouldRecord(rp *registry.RequestProfile, ap *registry.AttemptProfile) bool {
	record, _ := p.shouldRecordVerdict(rp, ap)
	return record
}

// providerProfileVerdict is what alwaysRecordRawVerdict learned about the
// retained raw provider profile: whether it decoded one, and the decoder's
// tags. The sink emits profiler.provider_profile from it for a sampled-out
// attempt (which never reaches applyProviderProfile, the persisted-row
// emitter) without a second decode.
type providerProfileVerdict struct {
	decoded    bool
	valid      bool
	reason     string
	enumFolded bool
}

// shouldRecordVerdict is shouldRecord that also returns the provider-profile
// verdict the always-record evaluation produced (zero when the request was
// sampled in, or when no raw profile was decoded).
func (p *profiler) shouldRecordVerdict(rp *registry.RequestProfile, ap *registry.AttemptProfile) (bool, providerProfileVerdict) {
	if p == nil || rp == nil || ap == nil {
		return false, providerProfileVerdict{}
	}
	if p.sampled(rp.CoordRequestID) {
		return true, providerProfileVerdict{}
	}
	return p.alwaysRecordRawVerdict(rp, ap)
}

// alwaysRecordRaw is alwaysRecord evaluated on the live profile: the same
// predicates, read from the fields buildProfileRecord would copy. The
// provider-profile predicate runs the retained raw profile through the same
// decoder (one <= 4 KB Unmarshal) so an invalid profile on a clean success
// is still force-recorded. TestAlwaysRecordRawMatchesFlattened pins parity.
func (p *profiler) alwaysRecordRaw(rp *registry.RequestProfile, ap *registry.AttemptProfile) bool {
	always, _ := p.alwaysRecordRawVerdict(rp, ap)
	return always
}

// alwaysRecordRawVerdict is alwaysRecordRaw that also returns what the
// provider-profile predicate decoded (decoded=false when an earlier
// predicate decided, or no raw profile was retained).
func (p *profiler) alwaysRecordRawVerdict(rp *registry.RequestProfile, ap *registry.AttemptProfile) (bool, providerProfileVerdict) {
	finalStatus, _, _, providerOutcome, _ := ap.Outcome()
	if deriveFinalStatus(finalStatus, providerOutcome) != finalStatusSuccess {
		return true, providerProfileVerdict{}
	}
	if v := ap.FirstContentUS.Load(); v > profileSlowFirstContent.Microseconds() {
		return true, providerProfileVerdict{}
	}
	if v := ap.FinalizedUS.Load(); v > profileSlowTotal.Microseconds() {
		return true, providerProfileVerdict{}
	}
	if rp.DispatchedAttempts() > 1 || ap.BackupLaunched.Load() || rp.ClientGonePhase() != "" {
		return true, providerProfileVerdict{}
	}
	if profileTimingAnomalyRaw(rp, ap) {
		return true, providerProfileVerdict{}
	}
	raw, late := ap.ProviderProfileRaw()
	switch {
	case len(raw) > 0:
		receivedAt := rp.T0
		if receivedAt.IsZero() {
			receivedAt = time.Now()
		}
		_, valid, reason, enumFolded := decodeInferenceProfile(raw, receivedAt)
		return !valid, providerProfileVerdict{decoded: true, valid: valid, reason: reason, enumFolded: enumFolded}
	case late:
		return true, providerProfileVerdict{}
	default:
		switch ap.ProviderProfileIngressStatus() {
		case registry.ProviderProfileTooLarge, registry.ProviderProfileDuplicate:
			return true, providerProfileVerdict{}
		}
		return false, providerProfileVerdict{}
	}
}

// alwaysRecord reports whether a flattened record bypasses sampling. The
// sink decides on the live profile (alwaysRecordRaw); this is the reference
// form the parity test checks it against.
func (p *profiler) alwaysRecord(rec *store.RequestProfileRecord) bool {
	if rec == nil {
		return false
	}
	if rec.FinalStatus != finalStatusSuccess {
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
	if !rec.ProviderProfileValid && rec.ProviderProfileInvalidReason != providerProfileAbsent {
		return true
	}
	return false
}

// finalizeAttemptProfile is the ProfileFinalizeFn installed on every request
// profile: build the row, apply sampling, enqueue.
func (s *Server) finalizeAttemptProfile(rp *registry.RequestProfile, ap *registry.AttemptProfile) {
	if s == nil || s.profiler == nil || !s.profiler.enabled || s.profiler.sink == nil {
		return
	}
	// Flattening and sampling happen on the sink worker (profileSink.build), so
	// the finalizing goroutine — possibly the provider WS read loop — only
	// performs one non-blocking channel send here.
	s.profiler.sink.submit(rp, ap)
}
