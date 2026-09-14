package registry

import (
	"math"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/routingcost"
)

// applyCacheRoutingCost reads the candidate's own snapshot (the scan
// builds it in place; no copy is taken). The caller holds r.mu, but not p.mu;
// the hint currency and affinity quarantine checks take the provider lock.
func (r *Registry) applyCacheRoutingCost(p *Provider, model string, pr *PendingRequest, candidate *routingCandidate) {
	_, present := pr.cacheRoutingHints[p.ID]
	if !present && pr.CachePlan.affinityKey == "" {
		return
	}
	p.mu.Lock()
	r.applyCacheRoutingCostPLocked(p, model, pr, candidate)
	p.mu.Unlock()
}

// applyCacheRoutingCostPLocked is shared by scan and reservation; both hold
// r.mu and p.mu so capability/quarantine checks use the current provider state.
func (r *Registry) applyCacheRoutingCostPLocked(p *Provider, model string, pr *PendingRequest, candidate *routingCandidate) {
	if pr.CachePlan.affinityKey != "" {
		candidate.cacheAffinityEligible = r.cacheAffinityEligibleLocked(p, model, pr.CachePlan)
	}
	r.applyCacheHintLocked(pr.cacheRoutingHints[p.ID], model, candidate)
}

// buildCandidateWithReason returns the candidate plus, on rejection,
// the reason so callers can split metrics by failure mode.
// now is the caller's scan clock (see snapshotProviderLockedEx). This is the
// by-value convenience form for cold callers (the commit re-check, the plan
// revalidation, tests); the fleet scan uses buildCandidateInto on an arena
// slot whose snapshot was filled in place.
func (r *Registry) buildCandidateWithReason(snap routingSnapshot, pr *PendingRequest, now time.Time) (*routingCandidate, candidateRejection, bool) {
	c := &routingCandidate{snapshot: snap}
	reason, _, ok := r.buildCandidateInto(c, pr, now)
	if !ok {
		return nil, reason, false
	}
	return c, rejectNone, true
}

// buildCandidateInto computes the routing cost for c from c.snapshot (already
// filled by snapshotProviderIntoLockedEx) and writes the cost fields into c.
// On rejection it returns the candidateRejection class the legacy counters
// split on (capacity / model-too-large / vision) AND the closed GateReason
// naming the exact drop, including the drops the candidateRejection enum
// reports as rejectNone (crashed/reloading slot, thermal critical), so the
// system-profiler routing record can tally them; c is then left partially
// written and must be discarded by the caller (the arena releases the slot).
// The counter semantics of candidateRejection are unchanged. Caller holds r.mu.
func (r *Registry) buildCandidateInto(c *routingCandidate, pr *PendingRequest, now time.Time) (candidateRejection, GateReason, bool) {
	snap := &c.snapshot
	statePenalty, eligible := routingcost.SlotStatePenalty(snap.SlotState)
	if !eligible {
		if snap.SlotState == "crashed" {
			return rejectNone, GateSlotCrashed, false
		}
		return rejectNone, GateSlotReloading, false
	}
	if !snap.HasHeadroom {
		return rejectCapacity, GateNoHeadroom, false
	}

	if snap.SystemMetrics.ThermalState == "critical" {
		return rejectNone, GateThermalCritical, false
	}

	reqMax := pr.RequestedMaxTokens
	if reqMax <= 0 {
		reqMax = defaultRequestedMaxTokens
	}
	reqPrompt := pr.EstimatedPromptTokens
	if reqPrompt < 0 {
		reqPrompt = 0
	}

	// Absolute hardware-fit gate (cold-load only, both admission modes). A model
	// whose footprint can never fit in this node's total memory must not be
	// routed here regardless of advertised token budget — otherwise the provider
	// 503s at load time ("Insufficient memory … need Y GB") and the request
	// bounces. This is the hole that let a 93.7 GB model get dispatched to 48/64
	// GB boxes: the token-budget admission path below never checked physical fit.
	//
	// Skip the gate whenever the model is already RESIDENT — a resident model has
	// demonstrably fit, so the heuristic must never reject it. The provider
	// reports "running" while actively serving and "idle" when loaded with no
	// in-flight requests (BatchScheduler+Telemetry: activeRequests>0 ? running :
	// idle); BOTH mean the weights are in GPU memory. SlotStateModelLoaded uses
	// that same resident vocabulary here and when fillSnapshotSlotState sets
	// snap.ModelLoaded. An idle-but-loaded provider therefore skips this gate.
	// Reported as rejectModelTooLarge (permanent, not capacity).
	if !routingcost.SlotStateModelLoaded(snap.SlotState) && !modelFitsHardware(snap.MinRAMGB, snap.ModelSizeGB, snap.TotalMemoryGB) {
		return rejectModelTooLarge, GateModelTooLarge, false
	}

	// Free-memory admission gate (Phase 1). A provider that claims to
	// serve the model but doesn't have headroom for weights + KV cache
	// is rejected here so we don't OOM the backend post-routing.
	if !freeMemoryAdmits(snap, reqPrompt, reqMax) {
		return rejectCapacity, GateFreeMemory, false
	}

	effectiveQueue := routingcost.Occupancy(snap)

	waitingBacklogTokens := float64(snap.BackendWaiting * reqMax)
	unaccountedPendingTokens := float64(snap.PendingMaxTokens) - float64(snap.MaxTokensPotential) - waitingBacklogTokens
	if unaccountedPendingTokens < 0 {
		unaccountedPendingTokens = 0
	}

	effectiveTPS := routingcost.ResolveEffectiveTPS(snap)

	queueMs := float64(effectiveQueue) * queueDepthPenaltyMs
	pendingMs := float64(snap.TotalPending) * totalPendingPenaltyMs
	var backlogMs float64
	if snap.ActiveTokenBudgetMax > 0 {
		tokensAhead := float64(snap.ActiveTokenBudgetUsed) + float64(snap.QueuedTokenBudget)
		backlogMs = tokensAhead / effectiveTPS * 1000.0
	} else {
		backlogMs = routingcost.BacklogTokenMs(snap.MaxTokensPotential, waitingBacklogTokens, unaccountedPendingTokens, effectiveTPS)
	}
	// Prefill resolves through routingcost.ResolvePrefillTPS for BOTH the base cost term and
	// the long-prompt bias below, so provider ranking follows the live measured
	// prefill EWMA when a slot reports one and only falls back to the static
	// registration/x12 chain when it does not. Reading snap.PrefillTPS directly
	// here pinned the dominant prefill term to the static rate, which left a box
	// whose measured prefill had degraded looking as cheap as its benchmark.
	prefillTPS := routingcost.ResolvePrefillTPS(snap)
	thisReqMs := float64(reqPrompt)/prefillTPS*1000.0 + float64(reqMax)/effectiveTPS*1000.0
	// Long-prompt fastest-tier preference: amplify the first-token-blocking time
	// for very long prompts so the provider that reaches first token soonest is
	// strongly preferred, reducing pre-first-token client_gone. The amplified
	// quantity is the FULL time-to-first-token (TTFT): prefill PLUS, for a COLD
	// provider, the model-load latency (statePenalty, ~30s). Prefill uses
	// routingcost.ResolvePrefillTPS (the live, observed-preferred prefill signal) — not the
	// static rate — so the bias follows real measured prefill and does not favor a
	// box whose static rate looks good but whose measured prefill is degraded.
	// Amplifying the full cold-load+prefill TTFT — not just prefill — prevents the
	// long-prompt bias from pulling a long prompt onto a cold box whose fast
	// prefill is dwarfed by the load and which is therefore slower end-to-end than
	// the fastest warm provider. Folded into thisReqMs so the cost breakdown
	// invariant (sum of terms == Total) holds. Returns 0 — and so leaves the cost
	// byte-for-byte unchanged — for short prompts and when the knob is off.
	prefillMs := float64(reqPrompt) / prefillTPS * 1000.0
	c.pricedPromptTokens = reqPrompt
	c.prefillCostMs = prefillMs + routingPolicy.LongPromptPenalty(reqPrompt, prefillMs)
	ttftBlockMs := prefillMs
	if !snap.ModelLoaded {
		// A cold provider must load before it can prefill; amplify its full
		// first-token latency (load + prefill), not just prefill, so the long-
		// prompt bias does not pull a long prompt onto a cold box that is slower
		// end-to-end than the fastest warm provider.
		ttftBlockMs += statePenalty
	}
	thisReqMs += routingPolicy.LongPromptPenalty(reqPrompt, ttftBlockMs)
	healthMs := routingcost.HealthPenaltyMs(snap.SystemMetrics, snap.GPUMemoryActiveGB, snap.TotalMemoryGB)
	// Gray-box capacity-503 rate penalty (faultstate/capacity_rate.go): a pair rejecting
	// a material fraction of dispatches with capacity 503s — while serving the
	// rest, so no zero-accepts breaker can see it — sinks in cost ranking
	// proportionally to its windowed reject rate. A soft derater, never an
	// ejection: the candidate stays in the pool, so a degraded-but-only fleet
	// still serves, and the penalty decays as outcomes age out of the window.
	capacityRateMs, capacityRejectRate := r.capacityRatePenaltyFor(snap.Provider, snap.Model, now)
	cost := statePenalty + queueMs + pendingMs + backlogMs + thisReqMs + healthMs + capacityRateMs

	// Estimated time-to-first-token for this candidate. Used for the
	// OpenRouter TTFT ceiling: public routes only select providers whose
	// estimated TTFT is within the per-request threshold. Providers without
	// BackendCapacity get 0 (unreliable estimate) and are not rejected by the
	// ceiling, matching the preflight behavior. The gate/ceiling input is the
	// CALIBRATED estimate (raw × learned actual/predicted ratio, see
	// routingcost/calibration.go); the raw value is kept alongside so the calibrator
	// learns against what the formula actually predicted.
	rawTTFTMs := routingcost.RawTTFTMs(snap, reqPrompt)
	if rawTTFTMs <= 0 || math.IsNaN(rawTTFTMs) || math.IsInf(rawTTFTMs, 0) {
		rawTTFTMs = 0
	}
	// Read the calibration ratio once and score with it, so the ratio the
	// profiler records is exactly the one this candidate was gated on.
	calibrationRatio := routingPolicy.AppliedRatio(snap.Model, snap.ChipFamily)
	ttftMs := routingcost.CalibratedTTFTMsWithRatio(snap, rawTTFTMs, calibrationRatio)

	c.provider = snap.Provider
	// The ratio the profiler records is exactly the one this candidate was
	// gated on (TTFTCalibrationRatio on the decision).
	c.calibrationRatio = calibrationRatio
	c.costMs = cost
	c.effectiveQueue = effectiveQueue
	c.effectiveTPS = effectiveTPS
	c.capacityRejectRate = capacityRejectRate
	c.breakdown = costBreakdown{
		StateMs:        statePenalty,
		QueueMs:        queueMs,
		PendingMs:      pendingMs,
		BacklogMs:      backlogMs,
		ThisReqMs:      thisReqMs,
		HealthMs:       healthMs,
		CapacityRateMs: capacityRateMs,
		TTFTMs:         ttftMs,
		RawTTFTMs:      rawTTFTMs,
		Total:          cost,
	}
	return rejectNone, GateReasonCount, true
}
