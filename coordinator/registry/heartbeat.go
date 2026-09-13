package registry

import (
	"log/slog"
	"math"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Sanity caps on provider-reported stats. A malicious (or broken) provider
// could otherwise report absurd values to monopolize routing. These caps are
// ~3-4x current hardware ceilings (M2 Ultra is ~800 GB/s, MLX decode is ~120
// tok/s, max Mac Studio RAM is 512 GB) so legitimate future hardware isn't
// clamped unnecessarily.
const (
	maxDecodeTPS                    = 500.0
	maxPrefillTPS                   = 5000.0
	maxMemoryBandwidthGBs           = 2000.0
	maxMemoryGB                     = 1024
	maxMemoryGBFloat                = 1024.0
	maxReportedMaxConcurrency       = 24
	maxTokensPotential              = 1_000_000
	maxTokenBudgetCap         int64 = 10_000_000_000 // 10 billion — generous safety valve for total token budget capacity
	maxModelLoadTimeMS        int64 = 3_600_000      // 1 hour — generous ceiling for a cold-start model load; larger is implausible/garbage
)

// clampNonNeg returns v clamped into [0, max]; NaN/negative become 0.
// The bool is true if the value was out of range.
func clampNonNeg(v, max float64) (float64, bool) {
	if math.IsNaN(v) || v < 0 {
		return 0, true
	}
	if v > max {
		return max, true
	}
	return v, false
}

// clampBackendCapacity applies sanity caps to provider-reported backend
// capacity fields that feed the routing scorer. A provider reporting
// TotalMemoryGB=1e9 would make gpuUtil ~= 0 and dodge health penalties, so
// we cap it at maxMemoryGBFloat. Same for MaxTokensPotential which directly
// controls backlog cost. NaN/negative become 0.
func clampBackendCapacity(logger *slog.Logger, providerID string, bc *protocol.BackendCapacity) {
	if bc == nil {
		return
	}
	if v, changed := clampNonNeg(bc.TotalMemoryGB, maxMemoryGBFloat); changed {
		logger.Warn("provider total_memory_gb out of range, clamping",
			"provider_id", providerID, "reported", bc.TotalMemoryGB, "clamped", v)
		bc.TotalMemoryGB = v
	}
	if v, changed := clampNonNeg(bc.GPUMemoryActiveGB, maxMemoryGBFloat); changed {
		logger.Warn("provider gpu_memory_active_gb out of range, clamping",
			"provider_id", providerID, "reported", bc.GPUMemoryActiveGB, "clamped", v)
		bc.GPUMemoryActiveGB = v
	}
	if v, changed := clampNonNeg(bc.GPUMemoryPeakGB, maxMemoryGBFloat); changed {
		bc.GPUMemoryPeakGB = v
	}
	if v, changed := clampNonNeg(bc.GPUMemoryCacheGB, maxMemoryGBFloat); changed {
		bc.GPUMemoryCacheGB = v
	}
	// free_for_load_gb: an out-of-range value (NaN/Inf/negative or absurdly high)
	// is treated as NOT reported (nil) so the cold-load gate falls back to the
	// total-memory heuristic, rather than trusting a garbage value that would
	// over- or under-admit. A legitimate 0 ("can't load anything now") is kept.
	if bc.FreeForLoadGB != nil {
		v := *bc.FreeForLoadGB
		if math.IsNaN(v) || math.IsInf(v, 0) || v < 0 || v > maxMemoryGBFloat {
			logger.Warn("provider free_for_load_gb out of range; ignoring (fall back to heuristic)",
				"provider_id", providerID, "reported", v)
			bc.FreeForLoadGB = nil
		}
	}
	if m := bc.PrefixCacheMaintenance; m != nil {
		m.TTLExpiredTotal = min(m.TTLExpiredTotal, maxCapacitySampleValue)
		m.BudgetEvictedTotal = min(m.BudgetEvictedTotal, maxCapacitySampleValue)
		m.TempRemovedTotal = min(m.TempRemovedTotal, maxCapacitySampleValue)
	}
	for i := range bc.Slots {
		s := &bc.Slots[i]
		s.PrefixCache = clampPrefixCacheTelemetry(s.PrefixCache)
		s.PagedStorage = clampPagedStorageTelemetry(s.PagedStorage)
		if s.MaxTokensPotential < 0 || s.MaxTokensPotential > maxTokensPotential {
			logger.Warn("provider slot max_tokens_potential out of range, clamping",
				"provider_id", providerID, "model", s.Model, "reported", s.MaxTokensPotential)
			if s.MaxTokensPotential < 0 {
				s.MaxTokensPotential = 0
			} else {
				s.MaxTokensPotential = maxTokensPotential
			}
		}
		if s.NumRunning < 0 {
			s.NumRunning = 0
		}
		if s.NumWaiting < 0 {
			s.NumWaiting = 0
		}
		if s.MaxConcurrency < 0 || s.MaxConcurrency > maxReportedMaxConcurrency {
			logger.Warn("provider slot max_concurrency out of range, clamping",
				"provider_id", providerID, "model", s.Model, "reported", s.MaxConcurrency)
			if s.MaxConcurrency < 0 {
				s.MaxConcurrency = 0
			} else {
				s.MaxConcurrency = maxReportedMaxConcurrency
			}
		}
		if v, changed := clampNonNeg(s.ObservedDecodeTPS, maxDecodeTPS); changed {
			logger.Warn("provider slot observed_decode_tps out of range, clamping",
				"provider_id", providerID, "model", s.Model, "reported", s.ObservedDecodeTPS, "clamped", v)
			s.ObservedDecodeTPS = v
		}
		// observed_prefill_tps: an out-of-range value (NaN/negative, or absurdly
		// high — a known provider-side overflow when the admitted→first-token
		// window collapses on a prefix-cache hit) is treated as NO measurement (0)
		// rather than clamped to the ceiling. Clamping garbage UP to maxPrefillTPS
		// would make the TTFT estimate over-optimistic (prefill looks instant) and
		// the hard gate over-accept; zeroing it makes resolvePrefillTPS fall back to
		// the conservative decode×ratio estimate until the provider reports a sane
		// value (provider fix: only sample cold prefills).
		if math.IsNaN(s.ObservedPrefillTPS) || s.ObservedPrefillTPS < 0 || s.ObservedPrefillTPS > maxPrefillTPS {
			logger.Warn("provider slot observed_prefill_tps out of range; ignoring (fall back to estimate)",
				"provider_id", providerID, "model", s.Model, "reported", s.ObservedPrefillTPS)
			s.ObservedPrefillTPS = 0
		}
		if s.ModelLoadTimeMS < 0 || s.ModelLoadTimeMS > maxModelLoadTimeMS {
			logger.Warn("provider slot model_load_time_ms out of range, clamping",
				"provider_id", providerID, "model", s.Model, "reported", s.ModelLoadTimeMS)
			if s.ModelLoadTimeMS < 0 {
				s.ModelLoadTimeMS = 0
			} else {
				s.ModelLoadTimeMS = maxModelLoadTimeMS
			}
		}
		if s.ActiveTokenBudgetUsed < 0 || s.ActiveTokenBudgetUsed > maxTokenBudgetCap {
			if s.ActiveTokenBudgetUsed < 0 {
				s.ActiveTokenBudgetUsed = 0
			} else {
				s.ActiveTokenBudgetUsed = maxTokenBudgetCap
			}
		}
		if s.ActiveTokenBudgetMax < 0 || s.ActiveTokenBudgetMax > maxTokenBudgetCap {
			if s.ActiveTokenBudgetMax < 0 {
				s.ActiveTokenBudgetMax = 0
			} else {
				s.ActiveTokenBudgetMax = maxTokenBudgetCap
			}
		}
		if s.QueuedTokenBudget < 0 || s.QueuedTokenBudget > maxTokenBudgetCap {
			if s.QueuedTokenBudget < 0 {
				s.QueuedTokenBudget = 0
			} else {
				s.QueuedTokenBudget = maxTokenBudgetCap
			}
		}
		if t := s.Telemetry; t != nil {
			// System-profiler slot telemetry (measurement only). Silent
			// clamps, like the token-budget fields above: nothing routes on
			// these, so a bad value is not worth a log line per heartbeat.
			// t is the registry-owned clone made by canonicalHeartbeatModelState.
			clampTelemetryCount(t.QueuedPrefillTokens)
			clampTelemetryCount(t.PartialPrefillRows)
			clampTelemetryCount(t.PrefillTokensTotal)
			clampTelemetryCount(t.PumpTasks)
			clampTelemetryCount(t.MTPRoundsTotal)
			clampTelemetryCount(t.MTPProposedTotal)
			clampTelemetryCount(t.MTPAcceptedTotal)
			clampTelemetryCount(t.DecodeRowsTotal)
			clampTelemetryInt64(t.KVBytesInUse, maxTelemetryBytes)
			clampTelemetryInt64(t.KVBytesCapacity, maxTelemetryBytes)
			clampTelemetryInt64(t.EvalInFlightMS, maxTelemetryMS)
			// Cumulative ns of engine step wall time: a count cap would wrap
			// after ~17 min of stepping, so it gets the wide ns bound.
			clampTelemetryInt64(t.StepWallNSTotal, maxTelemetryNSTotal)
			if p := t.IsolatedPrefillTPS; p != nil {
				if math.IsNaN(*p) || math.IsInf(*p, 0) {
					t.IsolatedPrefillTPS = nil // garbage reads as "not reported"
				} else if v, changed := clampNonNeg(*p, maxTelemetryTPS); changed {
					*p = v
				}
			}
		}
	}
	if t := bc.Telemetry; t != nil {
		clampTelemetryCount(t.MLXNumResources)
		clampTelemetryCount(t.InAdmission)
		clampTelemetryCount(t.InflightTasks)
		t.MemoryPressureLevel = t.MemoryPressureLevel.Fold()
		t.ProcessMemory = validProcessMemoryTelemetry(t.ProcessMemory)
	}
}

// System-profiler heartbeat telemetry bounds (CONTRACT-WIRE.md §2). Pointer
// numerics are clamped in place into [0, max]; nil (absent) is left alone so
// presence semantics survive.
const (
	maxTelemetryCount   int64   = 1_000_000_000_000 // 1e12
	maxTelemetryBytes   int64   = 1 << 48
	maxTelemetryMS      int64   = 3_600_000                 // 1 h
	maxTelemetryNSTotal int64   = 1_000_000_000_000_000_000 // 1e18 ≈ 31 y of cumulative ns
	maxTelemetryTPS     float64 = 20_000
)

func clampTelemetryInt64(p *int64, limit int64) {
	if p == nil {
		return
	}
	if *p < 0 {
		*p = 0
	} else if *p > limit {
		*p = limit
	}
}

func clampTelemetryCount(p *int64) { clampTelemetryInt64(p, maxTelemetryCount) }

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
	if v, changed := clampNonNeg(systemMetrics.MemoryPressure, 1.0); changed {
		systemMetrics.MemoryPressure = v
	}
	if v, changed := clampNonNeg(systemMetrics.CPUUsage, 1.0); changed {
		systemMetrics.CPUUsage = v
	}

	p.mu.Lock()
	eligibleModels := make([]protocol.ModelInfo, 0, len(p.Models))
	for _, model := range p.Models {
		if r.providerModelAllowedByCatalogLocked(p, model) {
			eligibleModels = append(eligibleModels, model)
		}
	}
	warmModels, currentModel, backendCapacity := canonicalHeartbeatModelState(
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
	clampBackendCapacity(r.logger, id, backendCapacity)
	now := time.Now()
	prevHB := p.LastHeartbeat
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
		}
	}
	// Credit wall-clock time since the previous heartbeat as uptime, so an
	// always-online provider's uptimeRate reaches 1.0 and its reputation can
	// exceed the old 0.85 cap (RecordUptime was never called in prod).
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
	// coalesced fleet-wide to one plan per modelSwapPlanInterval, since N
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

// canonicalHeartbeatModelState copies the provider-authored heartbeat model
// state while constraining every model identifier to the coordinator-accepted
// inventory for this connection. The returned values are owned by the
// registry; callers may clamp or retain them without mutating the decoded
// message. Duplicate known IDs are collapsed, so retained slice capacity is
// bounded by the accepted inventory rather than attacker-controlled heartbeat
// cardinality.
//
// Nil versus present-but-empty slices are preserved because both
// BackendCapacity and WarmModels use an empty snapshot to clear stale state.
// Unknown ActiveModel values are treated the same as no active model.
func canonicalHeartbeatModelState(
	models []protocol.ModelInfo,
	warmModels []string,
	activeModel *string,
	reportedCapacity *protocol.BackendCapacity,
) (canonicalWarm []string, canonicalActive string, canonicalCapacity *protocol.BackendCapacity) {
	accepted := make(map[string]struct{}, len(models))
	for _, model := range models {
		accepted[model.ID] = struct{}{}
	}

	if warmModels != nil {
		warmLimit := len(warmModels)
		if warmLimit > len(accepted) {
			warmLimit = len(accepted)
		}
		canonicalWarm = make([]string, 0, warmLimit)
		seenWarm := make(map[string]struct{}, warmLimit)
		for _, modelID := range warmModels {
			if _, ok := accepted[modelID]; !ok {
				continue
			}
			if _, duplicate := seenWarm[modelID]; duplicate {
				continue
			}
			seenWarm[modelID] = struct{}{}
			canonicalWarm = append(canonicalWarm, modelID)
		}
	}

	if activeModel != nil {
		if _, ok := accepted[*activeModel]; ok {
			canonicalActive = *activeModel
		}
	}

	if reportedCapacity == nil {
		return canonicalWarm, canonicalActive, nil
	}

	var capacity protocol.BackendCapacity
	cloneBackendCapacityFields(&capacity, reportedCapacity)
	if reportedCapacity.Slots != nil {
		slotLimit := len(reportedCapacity.Slots)
		if slotLimit > len(accepted) {
			slotLimit = len(accepted)
		}
		capacity.Slots = make([]protocol.BackendSlotCapacity, 0, slotLimit)
		seenSlots := make(map[string]struct{}, slotLimit)
		for index := range reportedCapacity.Slots {
			reportedSlot := &reportedCapacity.Slots[index]
			if _, ok := accepted[reportedSlot.Model]; !ok {
				continue
			}
			if _, duplicate := seenSlots[reportedSlot.Model]; duplicate {
				continue
			}
			seenSlots[reportedSlot.Model] = struct{}{}
			capacity.Slots = append(capacity.Slots, protocol.BackendSlotCapacity{})
			cloneBackendSlot(&capacity.Slots[len(capacity.Slots)-1], reportedSlot)
		}
	}

	return canonicalWarm, canonicalActive, &capacity
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
	cloneBackendCapacityFields(&capacity, p.BackendCapacity)
	if p.BackendCapacity.Slots != nil {
		capacity.Slots = make([]protocol.BackendSlotCapacity, len(p.BackendCapacity.Slots))
		for index := range p.BackendCapacity.Slots {
			cloneBackendSlot(&capacity.Slots[index], &p.BackendCapacity.Slots[index])
		}
	}
	return &capacity
}

// cloneBackendCapacityFields detaches the non-slot fields shared by heartbeat
// ingestion and public snapshots. Each caller fills Slots with its own filtered
// or complete copy, preserving nil versus present-empty snapshots.
func cloneBackendCapacityFields(capacity, in *protocol.BackendCapacity) {
	*capacity = *in
	capacity.Slots = nil
	if in.FreeForLoadGB != nil {
		free := *in.FreeForLoadGB
		capacity.FreeForLoadGB = &free
	}
	if in.MLXCacheReclaimer != nil {
		reclaimer := *in.MLXCacheReclaimer
		capacity.MLXCacheReclaimer = &reclaimer
	}
	if in.PrefixCacheMaintenance != nil {
		maintenance := *in.PrefixCacheMaintenance
		capacity.PrefixCacheMaintenance = &maintenance
	}
	capacity.Telemetry = in.Telemetry.Clone()
}

func cloneBackendSlot(slot, in *protocol.BackendSlotCapacity) {
	*slot = *in
	if slot.KVBackend != nil {
		backend := *slot.KVBackend
		slot.KVBackend = &backend
	}
	if slot.KVBackendFallbackReason != nil {
		reason := *slot.KVBackendFallbackReason
		slot.KVBackendFallbackReason = &reason
	}
	slot.Telemetry = slot.Telemetry.Clone()
	slot.PrefixCache = in.PrefixCache.Clone()
	slot.PagedStorage = in.PagedStorage.Clone()
}
