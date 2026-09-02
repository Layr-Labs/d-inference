package registry

import (
	"encoding/json"
	"math"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// fleet_sample.go — the fleet_snapshots producer (system profiler, slice 1).
// FleetSample emits one store.FleetSnapshotRow per (provider, resident slot)
// plus one provider-level row for a provider with no resident slot, and
// CoordinatorSample emits the single coordinator row. Both are called by the
// api layer's 60 s sampler goroutine; neither is on any request path, and
// neither may change any routing, queue, or client outcome.
//
// Lock discipline (no single r.mu hold longer than one provider's work):
//
//  1. ONE short r.mu.RLock copies the provider pointer list and nothing else.
//  2. Per provider, phase A takes only p.mu and copies every provider-level and
//     per-slot field into rows (no r.mu held).
//  3. Per provider, phase B takes r.mu.RLock briefly for the registry-side
//     state that lives in maps under r.mu (breaker, ejection, cooldowns, clamp,
//     effective cap, catalog membership) and for the eligibility verdict, which
//     deliberately reuses the routing gate itself (snapshotProviderReasonLockedEx
//     + buildCandidateGateLocked — the single source of routing eligibility).
//     p.mu is taken inside that RLock where needed (r.mu → p.mu is the
//     established order). A provider that disconnected between 1 and 3 is
//     dropped rather than sampled from stale registry state.
//
// Allocations are O(rows).

const (
	// fleetSampleProbePromptTokens / fleetSampleProbeMaxTokens shape the plain
	// text probe the eligibility verdict is evaluated for (matches the preflight
	// defaults in quickCapacityCheck).
	fleetSampleProbePromptTokens = 500
	fleetSampleProbeMaxTokens    = defaultRequestedMaxTokens
	coordinatorSampleProviderID  = "coordinator"
	// FleetSnapshotModelUncatalogued is the Model of a fleet_snapshots row whose
	// provider-reported slot model is not a coordinator-catalog id. Slot models
	// come from the provider-authored inventory, so a value the catalog does not
	// know is folded (the row is still emitted so its capacity stays visible).
	// A nil catalog (never synced, or sync failed) has no ids at all, so every
	// slot model folds — the row's Model is only ever a catalog id or this.
	FleetSnapshotModelUncatalogued = "uncatalogued"
)

// slotSampleScratch carries the per-slot inputs phase B needs that are not on
// the row itself.
type slotSampleScratch struct {
	rawModel       string
	rawRemaining   int64
	budgetReported bool
}

// FleetSample returns one row per (provider, resident slot) — plus one
// provider-level row (Model "") for a provider reporting no resident slot so
// every connected provider appears once — sampled at now. Model is a
// coordinator-catalog id or FleetSnapshotModelUncatalogued; SlotState and
// ThermalState are folded onto their closed vocabularies; EligibilityReason is
// the first failing routing gate for a plain text probe (GateReason names) or
// "eligible". The slice-2 heartbeat telemetry sub-objects (slot + capacity)
// and the cancel counters on HeartbeatStats are copied when present; a
// provider that predates them leaves those fields zero/nil. Every provider
// row carries the folded provider version (ProviderVersionFold) and every
// slot row the slot model's advertised IsVision / TemplateRenderOK, so a
// routing replay can reproduce the capability gates.
func (r *Registry) FleetSample(now time.Time) []store.FleetSnapshotRow {
	probe := &PendingRequest{
		RequestID:             "fleet-sample",
		EstimatedPromptTokens: fleetSampleProbePromptTokens,
		RequestedMaxTokens:    fleetSampleProbeMaxTokens,
	}
	// Step 1: one short read lock — the pointer list only.
	r.mu.RLock()
	providers := make([]*Provider, 0, len(r.providers))
	for _, p := range r.providers {
		providers = append(providers, p)
	}
	r.mu.RUnlock()

	rows := make([]store.FleetSnapshotRow, 0, len(providers)*2)
	for _, p := range providers {
		rows = r.appendProviderSample(rows, p, probe, now)
	}
	return rows
}

// appendProviderSample appends p's rows: phase A under p.mu only, phase B under
// a brief per-provider r.mu.RLock. Caller holds NO lock.
func (r *Registry) appendProviderSample(rows []store.FleetSnapshotRow, p *Provider, probe *PendingRequest, now time.Time) []store.FleetSnapshotRow {
	start := len(rows)

	// ---- Phase A: p.mu only. Copy every provider-level and per-slot field.
	p.mu.Lock()
	base := store.FleetSnapshotRow{
		SampledAt:  now,
		ProviderID: p.ID,
		SlotState:  string(SlotStateOther),
		// Bounded provider version (p.Version is guarded by p.mu) so a replay
		// can re-evaluate the capability version floors; "" when unreported.
		ProviderVersion: ProviderVersionFold(p.Version),
		HeartbeatAgeMs:  int(heartbeatAgeMs(now, p.LastHeartbeat)),
		MemoryPressure:  p.SystemMetrics.MemoryPressure,
		CPUUsage:        p.SystemMetrics.CPUUsage,
		ThermalState:    ThermalStateFold(p.SystemMetrics.ThermalState),
		PendingCount:    p.pendingCount(),
		MaxConcurrency:  p.maxConcurrency(),
		// HeartbeatStats cumulative counters, as reported (lifetime merge).
		RequestsServed:               p.Stats.RequestsServed,
		TokensGenerated:              p.Stats.TokensGenerated,
		CancellationsReceived:        p.Stats.CancellationsReceived,
		CancellationsBeforeOutput:    p.Stats.CancellationsBeforeOutput,
		CancellationsPartialComplete: p.Stats.CancellationsPartialComplete,
		GenerationErrorsAfterOutput:  p.Stats.GenerationErrorsAfterOutput,
		ChunkEncryptionErrors:        p.Stats.ChunkEncryptionErrors,
		StreamClosedWithoutTerminal:  p.Stats.StreamClosedWithoutTerminal,
		CancelDuringModelLoad:        p.Stats.CancelDuringModelLoad,
		UsageGaps:                    p.Stats.UsageGaps,
		CancelStagePreAcceptTotal:    p.Stats.CancelStagePreAcceptTotal,
		CancelStagePreEngineTotal:    p.Stats.CancelStagePreEngineTotal,
		CancelStagePrefillTotal:      p.Stats.CancelStagePrefillTotal,
		CancelStageDecodeTotal:       p.Stats.CancelStageDecodeTotal,
		CancelStagePostTerminalTotal: p.Stats.CancelStagePostTerminalTotal,
		TokensAfterCancelTotal:       p.Stats.TokensAfterCancelTotal,
		CancelAbortNSSum:             p.Stats.CancelAbortNSSum,
	}
	stableID := ""
	if healthEjectionEnabled() {
		stableID = stableProviderIdentityLocked(p)
	}
	heartbeatAt := p.LastHeartbeat
	bc := p.BackendCapacity
	if bc != nil {
		base.GPUMemoryActiveGB = bc.GPUMemoryActiveGB
		base.GPUMemoryPeakGB = bc.GPUMemoryPeakGB
		if bc.FreeForLoadGB != nil {
			base.FreeForLoadGB = *bc.FreeForLoadGB
		}
		// Slice-2 capacity telemetry (BackendCapacity.Telemetry); nil sub-object
		// (pre-slice-2 provider) leaves the fields nil/"". The level is folded onto
		// its closed vocabulary; pointers are copied by value so the row never
		// aliases the heartbeat struct. MLXNumResources / InAdmission /
		// InflightTasks have no FleetSnapshotRow column and are not sampled.
		if ct := bc.Telemetry; ct != nil {
			base.LowPowerMode = copyBoolPtr(ct.LowPowerMode)
			base.MemoryPressureLevel = string(ct.MemoryPressureLevel.Fold())
		}
	}
	var scratch []slotSampleScratch
	if bc == nil || len(bc.Slots) == 0 {
		// No resident slot: one provider-level row so the provider's liveness,
		// heartbeat age, breaker/ejection state and counters are still sampled.
		ClampFleetRowInts(&base)
		rows = append(rows, base)
	} else {
		scratch = make([]slotSampleScratch, len(bc.Slots))
		for i := range bc.Slots {
			slot := &bc.Slots[i]
			row := base
			row.Model = slot.Model // raw; folded against the catalog in phase B
			row.SlotState = string(SlotStateFold(slot.State))
			row.NumRunning = slot.NumRunning
			row.NumWaiting = slot.NumWaiting
			row.ActiveTokenBudgetUsed = slot.ActiveTokenBudgetUsed
			row.ActiveTokenBudgetMax = slot.ActiveTokenBudgetMax
			row.ObservedDecodeTPS = slot.ObservedDecodeTPS
			row.ObservedPrefillTPS = slot.ObservedPrefillTPS
			row.StepsExecuted = slot.StepsExecuted
			row.WedgeSuspected = slot.WedgeSuspected
			row.EvalInFlightMs = slot.EvalInFlightMs
			// Slice-2 slot telemetry (BackendSlotCapacity.Telemetry); nil sub-object
			// (pre-slice-2 provider) leaves every field zero/nil. Absent pointers
			// inside a present object read as 0 by contract. PumpTasks has no
			// FleetSnapshotRow column and is not sampled.
			if st := slot.Telemetry; st != nil {
				row.QueuedPrefillTokens = int(int64Or0(st.QueuedPrefillTokens))
				row.PartialPrefillRows = int(int64Or0(st.PartialPrefillRows))
				row.PrefillTokensTotal = int64Or0(st.PrefillTokensTotal)
				row.IsolatedPrefillTPS = float64Or0(st.IsolatedPrefillTPS)
				row.EWMAInitialized = copyBoolPtr(st.EWMAInitialized)
				row.MTPRoundsTotal = int64Or0(st.MTPRoundsTotal)
				row.MTPProposedTotal = int64Or0(st.MTPProposedTotal)
				row.MTPAcceptedTotal = int64Or0(st.MTPAcceptedTotal)
				row.KVBytesInUse = int64Or0(st.KVBytesInUse)
				row.KVBytesCapacity = int64Or0(st.KVBytesCapacity)
				row.StepWallNSTotal = int64Or0(st.StepWallNSTotal)
				row.DecodeRowsTotal = int64Or0(st.DecodeRowsTotal)
				// The telemetry object's eval_in_flight_ms supersedes the legacy
				// top-level slot field when present.
				if st.EvalInFlightMS != nil {
					row.EvalInFlightMs = *st.EvalInFlightMS
				}
			}
			if slot.MaxConcurrency > 0 {
				row.MaxConcurrency = slot.MaxConcurrency
			}
			// Capability flags of the slot model's advertised ModelInfo (p.Models
			// is guarded by p.mu): what the vision gate and the template-render
			// gate read at dispatch. A slot whose model the provider never
			// advertised leaves both zero/nil. The pointer is copied by value.
			for j := range p.Models {
				if p.Models[j].ID != slot.Model {
					continue
				}
				row.ModelVision = p.Models[j].IsVision
				row.TemplateRenderOK = copyBoolPtr(p.Models[j].TemplateRenderOK)
				break
			}
			row.PendingCount = p.pendingCountForModelLocked(slot.Model)
			scratch[i] = slotSampleScratch{
				rawModel:       slot.Model,
				rawRemaining:   slot.ActiveTokenBudgetMax - slot.ActiveTokenBudgetUsed - slot.QueuedTokenBudget,
				budgetReported: slot.ActiveTokenBudgetMax > 0,
			}
			ClampFleetRowInts(&row)
			rows = append(rows, row)
		}
	}
	p.mu.Unlock()

	// ---- Phase B: brief r.mu.RLock for this provider only.
	r.mu.RLock()
	defer r.mu.RUnlock()
	if r.providers[p.ID] != p {
		// Disconnected (or replaced) since the pointer list was copied: its
		// registry-side state is gone or belongs to a new session — drop it.
		return rows[:start]
	}
	breakerOpen := r.providerBreakerOpenLocked(p.ID, now)
	ejected := stableID != "" && r.healthEjectionOpenLocked(stableID, now)
	if scratch == nil {
		row := &rows[start]
		row.BreakerOpen = breakerOpen
		row.Ejected = ejected
		p.mu.Lock()
		ok, reason := r.providerLevelGateReasonLocked(p, now)
		p.mu.Unlock()
		if ok {
			row.EligibilityReason = EligibilityReasonEligible
		} else {
			row.EligibilityReason = reason.String()
		}
		return rows
	}
	shape := probe.Traits.CooldownShape()
	p.mu.Lock()
	for i := range scratch {
		row := &rows[start+i]
		raw := scratch[i].rawModel
		row.BreakerOpen = breakerOpen
		row.Ejected = ejected
		row.EffectiveCap = r.effectiveMaxConcurrencyForModelResolvedLocked(p, raw)
		row.CooldownActive = r.dispatchLoadCooldownActiveLocked(p.ID, raw, now) ||
			r.inferenceErrorCooldownActiveLocked(p.ID, raw, shape, now) ||
			r.capacityCooldownActiveLocked(p.ID, raw, now)
		row.ClampActive = r.budgetClampActiveLocked(p.ID, raw, heartbeatAt, scratch[i].rawRemaining, scratch[i].budgetReported, now)
	}
	p.mu.Unlock()
	// Eligibility via the real routing gates (the snapshot helper takes p.mu
	// itself, so p.mu must not be held here), then the catalog fold — the
	// gate reads the raw slot model, the persisted row never does.
	for i := range scratch {
		row := &rows[start+i]
		raw := scratch[i].rawModel
		row.EligibilityReason = r.slotEligibilityReasonLocked(p, raw, probe)
		row.Model = r.fleetSnapshotModelLocked(raw)
	}
	return rows
}

// fleetSnapshotModelLocked returns raw when it is a coordinator-catalog model
// id, else FleetSnapshotModelUncatalogued. Unlike IsModelInCatalog (a routing
// admission rule where a nil catalog means "filtering disabled"), a nil
// catalog here folds everything: with no catalog there is no id to vouch for
// the provider-authored string. Caller holds r.mu (read).
func (r *Registry) fleetSnapshotModelLocked(raw string) string {
	if r.modelCatalog == nil {
		return FleetSnapshotModelUncatalogued
	}
	if _, ok := r.modelCatalog[raw]; ok {
		return raw
	}
	return FleetSnapshotModelUncatalogued
}

// slotEligibilityReasonLocked evaluates the FULL routing eligibility of
// (p, model) for a plain text probe — the same providerRoutingGateReasonLockedEx
// + buildCandidateGateLocked pipeline the dispatch scan runs — and returns the
// first failing GateReason name or "eligible". Caller holds r.mu (read) and
// must NOT hold p.mu (the snapshot helper takes it).
func (r *Registry) slotEligibilityReasonLocked(p *Provider, model string, probe *PendingRequest) string {
	snap, ok, reason := r.snapshotProviderReasonLockedEx(p, model, probe.Traits, false, false)
	if !ok {
		return reason.String()
	}
	if _, _, gateReason, built := r.buildCandidateGateLocked(snap, probe); !built {
		return gateReason.String()
	}
	return EligibilityReasonEligible
}

// providerLevelGateReasonLocked is the provider-scoped subset of the routing
// gate (node-health breaker, health ejection, liveness/trust/privacy core) for
// a provider with no resident slot to evaluate a model against. Caller holds
// r.mu (read) and p.mu.
func (r *Registry) providerLevelGateReasonLocked(p *Provider, now time.Time) (bool, GateReason) {
	if r.providerBreakerOpenLocked(p.ID, now) {
		return false, GateBreaker
	}
	if healthEjectionEnabled() {
		if sid := stableProviderIdentityLocked(p); sid != "" && r.healthEjectionOpenLocked(sid, now) {
			return false, GateEjection
		}
	}
	return r.providerLivenessGateReasonLocked(p, r.MinTrustLevel, false, now)
}

// int64Or0 / float64Or0 / copyBoolPtr read the optional pointer fields of the
// heartbeat telemetry sub-objects: absent == 0/nil by contract, and a present
// bool is copied by value so a row never aliases the heartbeat struct.
func int64Or0(v *int64) int64 {
	if v == nil {
		return 0
	}
	return *v
}

func float64Or0(v *float64) float64 {
	if v == nil {
		return 0
	}
	return *v
}

func copyBoolPtr(v *bool) *bool {
	if v == nil {
		return nil
	}
	b := *v
	return &b
}

// CoordinatorSample returns the per-tick coordinator row (ProviderID
// "coordinator"): total queue depth, queue depth by model (JSON object keyed
// by the coordinator-resolved model id), and the number of in-flight
// (coordinator-pending) requests across the fleet. It reads the queue through
// the non-sweeping QueueDepths accessor: sampling never expires a stale waiter
// or signals any client. The api layer adds the sink / lock-wait / goroutine
// counters it owns.
func (r *Registry) CoordinatorSample(now time.Time) store.FleetSnapshotRow {
	row := store.FleetSnapshotRow{
		SampledAt:  now,
		ProviderID: coordinatorSampleProviderID,
		SlotState:  string(SlotStateOther),
	}
	r.mu.RLock()
	queue := r.queue
	providers := make([]*Provider, 0, len(r.providers))
	for _, p := range r.providers {
		providers = append(providers, p)
	}
	r.mu.RUnlock()
	inflight := 0
	for _, p := range providers {
		inflight += p.PendingCount()
	}
	row.InflightRequests = inflight

	// The queue has its own mutex and is never nested under r.mu: read it after
	// the registry lock is released.
	if queue != nil {
		total, byModel := queue.QueueDepths()
		row.QueueDepthTotal = total
		if len(byModel) > 0 {
			// encoding/json sorts map keys, so the object is deterministic.
			if raw, err := json.Marshal(byModel); err == nil {
				row.QueueDepthByModel = raw
			}
		}
	}
	ClampFleetRowInts(&row)
	return row
}

// clampFleetInt bounds a heartbeat-reported count to the INT columns of
// fleet_snapshots so one absurd value cannot abort the whole CopyFrom batch.
func clampFleetInt(v int) int {
	if v > math.MaxInt32 {
		return math.MaxInt32
	}
	if v < math.MinInt32 {
		return math.MinInt32
	}
	return v
}

// ClampFleetRowInts applies clampFleetInt to every int column of a row. The
// api sampler calls it again after filling its own fields on the coordinator row.
func ClampFleetRowInts(r *store.FleetSnapshotRow) {
	r.NumRunning = clampFleetInt(r.NumRunning)
	r.NumWaiting = clampFleetInt(r.NumWaiting)
	r.QueuedPrefillTokens = clampFleetInt(r.QueuedPrefillTokens)
	r.PartialPrefillRows = clampFleetInt(r.PartialPrefillRows)
	r.MaxConcurrency = clampFleetInt(r.MaxConcurrency)
	r.PendingCount = clampFleetInt(r.PendingCount)
	r.EffectiveCap = clampFleetInt(r.EffectiveCap)
	r.HeartbeatAgeMs = clampFleetInt(r.HeartbeatAgeMs)
	r.QueueDepthTotal = clampFleetInt(r.QueueDepthTotal)
	r.InflightRequests = clampFleetInt(r.InflightRequests)
	r.ProfileSinkDepth = clampFleetInt(r.ProfileSinkDepth)
	r.Goroutines = clampFleetInt(r.Goroutines)
}
