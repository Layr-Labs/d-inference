package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Heartbeat updates the provider's status and stats and reports whether the
// snapshot was accepted. Rejected stale snapshots still advance liveness.
func (r *Registry) Heartbeat(id string, msg *protocol.HeartbeatMessage) bool {
	r.mu.RLock()
	p, ok := r.providers[id]
	if !ok {
		r.mu.RUnlock()
		r.logger.Warn("heartbeat from unknown provider", "provider_id", id)
		return false
	}

	// Work from registry-owned copies so clamping and retention never mutate the
	// decoded provider message. Model-bearing fields are canonicalized after
	// taking p.mu below, against the same p.Models snapshot that remains
	// authoritative for the rest of this heartbeat.
	systemMetrics := msg.SystemMetrics
	if v, changed := capacityvalue.ClampNonNeg(systemMetrics.MemoryPressure, 1.0); changed {
		systemMetrics.MemoryPressure = v
	}
	if v, changed := capacityvalue.ClampNonNeg(systemMetrics.CPUUsage, 1.0); changed {
		systemMetrics.CPUUsage = v
	}

	p.mu.Lock()
	reportedAutopilotCapacity := p.autopilotState.ReportedCapacity(msg.BackendCapacity)
	eligibleModels := make([]protocol.ModelInfo, 0, len(p.Models))
	for _, model := range p.Models {
		if r.providerModelAllowedByCatalogLocked(p, model) {
			eligibleModels = append(eligibleModels, model)
		}
	}
	warmController := r.warmPool
	// Capture public work eligibility while the registry and provider locks
	// protect the same routing-policy snapshot. Reconciliation below holds only
	// p.mu, so it must not reacquire r.mu in the reverse order.
	workModels := r.warmPoolWorkModelsLocked(p, eligibleModels, msg.Status, time.Now())
	warmModels, currentModel, backendCapacity := capacityvalue.CanonicalHeartbeatModelState(
		eligibleModels, msg.WarmModels, msg.ActiveModel, msg.BackendCapacity)
	r.mu.RUnlock()
	// Routing v2 W2 — capacity_seq gate. Event-triggered heartbeats share the
	// bounded data lane with the 5s baseline, so an event frame published
	// AFTER a baseline frame can be decoded BEFORE it (two frames in the
	// writer queue, read-loop dispatch order vs. publish order is not the
	// coordinator's to assume). Applying the older snapshot second would
	// regress fresher slot/budget state — exactly the staleness window the
	// event heartbeats exist to close. Seq ordering is per-connection: a
	// reconnect restarts the provider's counter AND creates a fresh *Provider
	// (capacitySeq zero), so cross-connection comparisons never happen.
	//
	// The gate reads msg.BackendCapacity (the wire truth) rather than the
	// canonicalized copy: canonicalization can drop slots but never reorders
	// frames. Seq 0/omitted is a legacy provider — every legacy heartbeat
	// takes the unguarded path below, byte-identical to today.
	if msg.BackendCapacity != nil && msg.BackendCapacity.CapacitySeq > 0 {
		if msg.BackendCapacity.CapacitySeq <= p.capacitySeq {
			// Stale/reordered frame: discard the ENTIRE application — capacity,
			// KV/TPS observations, warm/current model, status, and the clamp
			// release proof all derive from this one out-of-date snapshot.
			// LastHeartbeat still advances: the frame proves the connection is
			// alive, and eviction must key on liveness, not snapshot ordering.
			// Uptime credit and stats deltas are deliberately NOT applied — a
			// fresher frame just applied them microseconds ago (that is the
			// only way this branch is reachable), so nothing is lost.
			appliedSeq := p.capacitySeq
			p.LastHeartbeat = time.Now()
			p.mu.Unlock()
			r.logger.Debug("discarding stale capacity heartbeat",
				"provider_id", id, "seq", msg.BackendCapacity.CapacitySeq, "applied_seq", appliedSeq)
			return false
		}
		p.capacitySeq = msg.BackendCapacity.CapacitySeq
		// Seq-stamping providers implement the wave-2 capacity protocol:
		// mark the session quote-capable so the probe fanout can find it.
		p.capacityQuoteCapable = true
	}
	// Clamp only after unknown slot identifiers have been removed. Besides
	// keeping them out of routing state, this prevents an unaccepted model ID
	// from reaching clamp diagnostics or TPS/KV observations.
	capacityvalue.ClampBackendCapacity(r.logger, id, backendCapacity)
	clock := r.heartbeatNow
	if clock == nil {
		clock = time.Now
	}
	now := clock()
	// Inspect the accepted wire snapshot before catalog filtering can hide an
	// unrelated model's activity. A stale sequence never changes these clocks.
	p.reconcileDeadlineApplicabilityLocked(msg.BackendCapacity, systemMetrics, now)
	prevHB := p.LastHeartbeat
	p.reconcileFirstContentMeasurementsLocked(backendCapacity, now)
	p.reconcileWarmPoolWorkLocked(backendCapacity, now, warmController, workModels)
	p.reconcileCapacitySamplesLocked(backendCapacity, now)
	p.LastHeartbeat = now
	applyHeartbeatStatsDelta(&p.Stats, p.lastSessionStats, msg.Stats)
	p.lastSessionStats = mergeHeartbeatSessionStats(p.lastSessionStats, msg.Stats)
	p.SystemMetrics = systemMetrics
	// Idle-memory policy: copy so the registry never aliases the decoded
	// message; ignore nonsense (negative) values from an untrusted provider.
	if msg.IdleUnloadMins != nil && *msg.IdleUnloadMins >= 0 {
		v := *msg.IdleUnloadMins
		p.IdleUnloadMins = &v
	}
	// Update backend capacity from heartbeat. A nil report clears prior live
	// capacity so stale slot state cannot keep influencing routing.
	p.BackendCapacity = backendCapacity
	r.reconcileAutopilotHeartbeatLocked(p, msg.ModelAutopilot, reportedAutopilotCapacity, now)
	if backendCapacity != nil && backendCapacity.WholeMacServiceRetirementProtocol == 1 && backendCapacity.WholeMacServiceUsed != nil {
		p.serviceRetirementProtocol = true
	}
	p.CapacityAcceptedAt = time.Time{}
	if backendCapacity != nil {
		p.CapacityAcceptedAt = now
	}
	// Bind the owner-facing readiness model set to this exact applied capacity
	// snapshot. Catalog changes or model replacements take effect on the next
	// heartbeat, never halfway through an owner read.
	p.CapacityModelIDs = make([]string, 0, len(eligibleModels))
	for _, model := range eligibleModels {
		p.CapacityModelIDs = append(p.CapacityModelIDs, model.ID)
	}
	// Per-slot KV backend (v0.8.0 paged rollout). Recorded from the canonical
	// report after unaccepted model identifiers have been removed,
	// BEFORE the nil-clearing semantics above take effect for it: the record is
	// sticky across a slot vanishing from the heartbeat, because attribution of
	// an in-flight request must survive its slot crashing. Measurement only —
	// nothing below reads it. See kv_backend.go.
	p.recordKVBackendsLocked(backendCapacity)
	if p.BackendCapacity != nil {
		chipFamily := p.Hardware.ChipFamily
		// Solo samples are keyed by chip CLASS (family+tier, chipClassKey) so a
		// fast tier (M4 Max) never lends its rate to a slow one (M4 Pro); the
		// load-inclusive Record stays family-keyed (fleetMedianTPS semantics).
		chipClass := chipClassKey(p.Hardware)
		// Solo gate: a slot EWMA is additionally recorded as a SOLO sample only
		// when the whole box is uncontended at heartbeat time (Σ running+waiting
		// ≤ 1 across ALL slots — the one allowance is the sample-generating
		// request itself) AND the slot has an actual RUNNING decode
		// (NumRunning > 0). Both halves matter. Requiring NumRunning (not
		// running+waiting) excludes a purely-QUEUED box: the provider reports
		// NumWaiting from its pending set while ObservedDecodeTPS is a retained
		// EWMA (BatchScheduler+Telemetry.swift), so a box with one queued-but-
		// not-yet-decoding request would otherwise mint that stale EWMA as a
		// fresh solo sample every ~30s heartbeat and, once the min-sample floor
		// is reached, base the model's quality cap on traffic no running request
		// produced. It also keeps the prior round's owner-slot-only rule: an
		// idle co-resident slot with a decayed EWMA is NumRunning == 0, so it is
		// never re-sampled, and a fully idle box records nothing. The
		// unconditional Record keeps its
		// load-inclusive semantics for TTFT estimation (fleetMedianTPS); the
		// gated RecordSolo feeds the quality-concurrency cap's per-model static
		// rate (resolvedSoloModelTPSLocked). See solo_tps.go.
		soloEligible := soloSampleEligible(p.BackendCapacity)
		for _, slot := range p.BackendCapacity.Slots {
			if slot.ObservedDecodeTPS > 0 {
				r.tpsRegistry.Record(slot.Model, chipFamily, slot.ObservedDecodeTPS)
				if soloEligible && slot.NumRunning > 0 {
					r.tpsRegistry.RecordSolo(slot.Model, chipClass, slot.ObservedDecodeTPS)
				}
			}
			if prefill, ok := slotIsolatedPrefillTPS(&slot); ok {
				r.tpsRegistry.RecordPrefill(slot.Model, chipFamily, prefill)
			}
		}
	}
	// Credit wall-clock time since the previous heartbeat as provider uptime.
	// Bound the credit to a window just above the heartbeat interval (30s) and
	// within the eviction staleness (90s): a larger gap means the provider was
	// effectively offline (it would have been reaped, or this is an in-process
	// stall) and must NOT be credited. A fresh registration sets LastHeartbeat
	// to registration time, so the first real heartbeat credits ~one interval.
	// Must run under p.mu (held here) — p.Reputation is mutated under p.mu by
	// the job/challenge handlers.
	if !prevHB.IsZero() {
		const maxUptimeCredit = 2 * time.Minute
		if delta := now.Sub(prevHB); delta > 0 && delta <= maxUptimeCredit {
			p.Reputation.RecordUptime(delta)
		}
	}
	// Update warm models from heartbeat. Always overwrite -- an empty list
	// means the provider has no models loaded, and stale entries must be
	// cleared to prevent TriggerModelSwaps from suppressing needed swaps.
	p.WarmModels = warmModels
	// A nil or unaccepted active_model means no coordinator-known model is
	// loaded. Clear stale state so challenge checks never compare against a
	// provider-injected identifier.
	p.CurrentModel = currentModel
	// Drain awareness (drain_state.go): "draining" arms the routing skip,
	// "idle"/"serving" clear it. Independent of p.Status below — a draining
	// provider keeps its online/serving accounting; only routing changes.
	applyHeartbeatDrainStateLocked(p, msg.Status, now)
	// A post-commit serving heartbeat is the provider's refreshed capacity
	// snapshot. Only an applied, non-nil backend report may release a model
	// replacement; a pre-resume draining frame or stale capacity_seq cannot.
	if backendCapacity != nil {
		p.drain.AppliedCapacity(msg.Status, backendCapacity.CapacitySeq)
	}
	// Only update status from heartbeat if provider is not actively serving
	// (serving status is managed by request lifecycle). Crucially, an
	// untrusted provider must NOT transition back to StatusOnline here —
	// that would cause an onlineCount double-decrement when Disconnect
	// later sees StatusOnline and decrements a second time.
	if p.Status == StatusUntrusted {
		// no status transitions allowed
	} else if p.Status != StatusServing || msg.Status == "idle" {
		switch msg.Status {
		case "idle":
			p.Status = StatusOnline
		case "serving":
			p.Status = StatusServing
		}
	}
	// Backstop for the per-model provider index: allocation-free when p.Models
	// is already in step, and self-healing within one heartbeat otherwise.
	p.syncModelIndexLocked()
	p.mu.Unlock()

	// This heartbeat may be the release proof for a budget clamp
	// (budget_clamp.go): drop any clamp entry this heartbeat's snapshot proves
	// inactive so a released pair returns to the accept fast path and cannot
	// be re-blocked by a lingering entry on its next reconnect. The sweep
	// evaluates the heartbeat's OWN stamped time and report (not a re-read of
	// the provider), so a racing disconnect cannot void the release proof.
	// Cheap no-op probe when the provider has no clamp state.
	r.releaseBudgetClampsOnHeartbeat(id, now, backendCapacity)

	r.PersistProviderThrottled(p)
	// Persist accumulated uptime (throttled) so it survives restarts/reconnects;
	// the heartbeat path is otherwise the only place uptime grows.
	r.persistReputationThrottled(p)

	// Heartbeats can make a recovered slot routable again (for example after a
	// crash auto-restart). Drain matching queues using the canonical scheduler
	// rather than the legacy direct queue assignment path. Heartbeats are the
	// one trigger that is rate-limited after a saturated pass
	// (queue_drain_suppress.go); every capacity-freeing trigger drains at once.
	r.drainQueuedRequestsForHeartbeat(providerModelIDs(p))

	// If queue drain didn't satisfy all pending requests (no warm provider),
	// check if a cold provider should swap models to serve queued demand —
	// coalesced fleet-wide to one plan per swapplan.Interval, since N
	// heartbeats inside that window would each re-derive the same plan; a
	// heartbeat the window refuses arms one trailing plan for its end
	// (model_swap_coalesce.go). Drain work can outlast the planning window,
	// so claim against the current time rather than the heartbeat timestamp.
	r.triggerModelSwapsFromHeartbeat(time.Now())
	return true
}

func cumulativeDelta(previous, current int64) int64 {
	if current <= 0 {
		return 0
	}
	if current >= previous {
		return current - previous
	}
	// The provider process restarted and reset its in-memory counters.
	return current
}

func applyHeartbeatStatsDelta(total *protocol.HeartbeatStats, previous, current protocol.HeartbeatStats) {
	total.RequestsServed += cumulativeDelta(previous.RequestsServed, current.RequestsServed)
	total.TokensGenerated += cumulativeDelta(previous.TokensGenerated, current.TokensGenerated)
	total.CancellationsReceived += cumulativeDelta(previous.CancellationsReceived, current.CancellationsReceived)
	total.CancellationsBeforeOutput += cumulativeDelta(previous.CancellationsBeforeOutput, current.CancellationsBeforeOutput)
	total.CancellationsPartialComplete += cumulativeDelta(previous.CancellationsPartialComplete, current.CancellationsPartialComplete)
	total.GenerationErrorsAfterOutput += cumulativeDelta(previous.GenerationErrorsAfterOutput, current.GenerationErrorsAfterOutput)
	total.ChunkEncryptionErrors += cumulativeDelta(previous.ChunkEncryptionErrors, current.ChunkEncryptionErrors)
	total.StreamClosedWithoutTerminal += cumulativeDelta(previous.StreamClosedWithoutTerminal, current.StreamClosedWithoutTerminal)
	total.CancelDuringModelLoad += cumulativeDelta(previous.CancelDuringModelLoad, current.CancelDuringModelLoad)
	total.UsageGaps += cumulativeDelta(previous.UsageGaps, current.UsageGaps)
	// System profiler cancel accountability counters (cumulative per session).
	total.CancelStagePreAcceptTotal += cumulativeDelta(previous.CancelStagePreAcceptTotal, current.CancelStagePreAcceptTotal)
	total.CancelStagePreEngineTotal += cumulativeDelta(previous.CancelStagePreEngineTotal, current.CancelStagePreEngineTotal)
	total.CancelStagePrefillTotal += cumulativeDelta(previous.CancelStagePrefillTotal, current.CancelStagePrefillTotal)
	total.CancelStageDecodeTotal += cumulativeDelta(previous.CancelStageDecodeTotal, current.CancelStageDecodeTotal)
	total.CancelStagePostTerminalTotal += cumulativeDelta(previous.CancelStagePostTerminalTotal, current.CancelStagePostTerminalTotal)
	total.TokensAfterCancelTotal += cumulativeDelta(previous.TokensAfterCancelTotal, current.TokensAfterCancelTotal)
	total.CancelAbortNSSum += cumulativeDelta(previous.CancelAbortNSSum, current.CancelAbortNSSum)
}

func mergeHeartbeatSessionStats(previous, current protocol.HeartbeatStats) protocol.HeartbeatStats {
	merged := current
	if merged.CancellationsReceived == 0 {
		merged.CancellationsReceived = previous.CancellationsReceived
	}
	if merged.CancellationsBeforeOutput == 0 {
		merged.CancellationsBeforeOutput = previous.CancellationsBeforeOutput
	}
	if merged.CancellationsPartialComplete == 0 {
		merged.CancellationsPartialComplete = previous.CancellationsPartialComplete
	}
	if merged.GenerationErrorsAfterOutput == 0 {
		merged.GenerationErrorsAfterOutput = previous.GenerationErrorsAfterOutput
	}
	if merged.ChunkEncryptionErrors == 0 {
		merged.ChunkEncryptionErrors = previous.ChunkEncryptionErrors
	}
	if merged.StreamClosedWithoutTerminal == 0 {
		merged.StreamClosedWithoutTerminal = previous.StreamClosedWithoutTerminal
	}
	if merged.CancelDuringModelLoad == 0 {
		merged.CancelDuringModelLoad = previous.CancelDuringModelLoad
	}
	if merged.UsageGaps == 0 {
		merged.UsageGaps = previous.UsageGaps
	}
	for _, f := range []struct{ cur, prev *int64 }{
		{&merged.CancelStagePreAcceptTotal, &previous.CancelStagePreAcceptTotal},
		{&merged.CancelStagePreEngineTotal, &previous.CancelStagePreEngineTotal},
		{&merged.CancelStagePrefillTotal, &previous.CancelStagePrefillTotal},
		{&merged.CancelStageDecodeTotal, &previous.CancelStageDecodeTotal},
		{&merged.CancelStagePostTerminalTotal, &previous.CancelStagePostTerminalTotal},
		{&merged.TokensAfterCancelTotal, &previous.TokensAfterCancelTotal},
		{&merged.CancelAbortNSSum, &previous.CancelAbortNSSum},
	} {
		if *f.cur == 0 {
			*f.cur = *f.prev
		}
	}
	return merged
}

// BackendCapacitySnapshot returns a detached copy of the last accepted
// heartbeat capacity. Callers outside the registry must use this instead of
// the decoded heartbeat: the registry copy has already dropped model IDs that
// were not part of this connection's coordinator-accepted inventory.
func (p *Provider) BackendCapacitySnapshot() *protocol.BackendCapacity {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.BackendCapacity == nil {
		return nil
	}

	var capacity protocol.BackendCapacity
	capacityvalue.CloneBackendCapacityFields(&capacity, p.BackendCapacity)
	if p.BackendCapacity.Slots != nil {
		capacity.Slots = make([]protocol.BackendSlotCapacity, len(p.BackendCapacity.Slots))
		for index := range p.BackendCapacity.Slots {
			capacityvalue.CloneBackendSlot(&capacity.Slots[index], &p.BackendCapacity.Slots[index])
		}
	}
	return &capacity
}
