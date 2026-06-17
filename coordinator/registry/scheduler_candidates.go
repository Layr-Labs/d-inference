package registry

import (
	"math"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// buildCandidateWithReason returns the candidate plus, on rejection,
// the reason so callers can split metrics by failure mode.
func (r *Registry) buildCandidateWithReason(snap routingSnapshot, pr *PendingRequest) (*routingCandidate, candidateRejection, bool) {
	statePenalty, eligible := slotStatePenalty(snap.slotState)
	if !eligible {
		return nil, rejectNone, false
	}
	if !snap.hasHeadroom {
		return nil, rejectCapacity, false
	}

	if snap.systemMetrics.ThermalState == "critical" {
		return nil, rejectNone, false
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
	// idle); BOTH mean the weights are in GPU memory. `snap.modelLoaded` only
	// tracks "running", so we check the slot state directly here — otherwise an
	// idle-but-loaded provider would be wrongly excluded. Reported as
	// rejectModelTooLarge (permanent, not capacity).
	if !slotStateModelLoaded(snap.slotState) && !modelFitsHardware(snap.minRAMGb, snap.modelSizeGB, snap.totalMemoryGB) {
		return nil, rejectModelTooLarge, false
	}

	// Free-memory admission gate (Phase 1). A provider that claims to
	// serve the model but doesn't have headroom for weights + KV cache
	// is rejected here so we don't OOM the backend post-routing.
	if !freeMemoryAdmits(snap, reqPrompt, reqMax) {
		return nil, rejectCapacity, false
	}

	effectiveQueue := snap.pendingForModel
	backendDepth := snap.backendRunning + snap.backendWaiting
	if backendDepth > effectiveQueue {
		effectiveQueue = backendDepth
	}

	waitingBacklogTokens := float64(snap.backendWaiting * reqMax)
	unaccountedPendingTokens := float64(snap.pendingMaxTokens) - float64(snap.maxTokensPotential) - waitingBacklogTokens
	if unaccountedPendingTokens < 0 {
		unaccountedPendingTokens = 0
	}

	effectiveTPS := resolveEffectiveTPS(snap)

	queueMs := float64(effectiveQueue) * queueDepthPenaltyMs
	pendingMs := float64(snap.totalPending) * totalPendingPenaltyMs
	var backlogMs float64
	if snap.activeTokenBudgetMax > 0 {
		tokensAhead := float64(snap.activeTokenBudgetUsed) + float64(snap.queuedTokenBudget)
		backlogMs = tokensAhead / effectiveTPS * 1000.0
	} else {
		backlogMs = backlogTokenMs(snap.maxTokensPotential, waitingBacklogTokens, unaccountedPendingTokens, effectiveTPS)
	}
	thisReqMs := float64(reqPrompt)/snap.prefillTPS*1000.0 + float64(reqMax)/effectiveTPS*1000.0
	healthMs := healthPenaltyMs(snap.systemMetrics, snap.gpuMemoryActiveGB, snap.totalMemoryGB)
	cost := statePenalty + queueMs + pendingMs + backlogMs + thisReqMs + healthMs

	// Estimated time-to-first-token for this candidate. Used for the
	// OpenRouter TTFT ceiling: public routes only select providers whose
	// estimated TTFT is within the per-request threshold. Providers without
	// BackendCapacity get 0 (unreliable estimate) and are not rejected by the
	// ceiling, matching the preflight behavior.
	ttftMs := ttftMsFromSnapshot(snap, reqPrompt)
	if ttftMs <= 0 || math.IsNaN(ttftMs) || math.IsInf(ttftMs, 0) {
		ttftMs = 0
	}

	return &routingCandidate{
		provider:       snap.provider,
		snapshot:       snap,
		costMs:         cost,
		effectiveQueue: effectiveQueue,
		effectiveTPS:   effectiveTPS,
		breakdown: costBreakdown{
			StateMs:   statePenalty,
			QueueMs:   queueMs,
			PendingMs: pendingMs,
			BacklogMs: backlogMs,
			ThisReqMs: thisReqMs,
			HealthMs:  healthMs,
			TTFTMs:    ttftMs,
			Total:     cost,
		},
	}, rejectNone, true
}

func estimatedTTFTFromSnapshot(snap routingSnapshot, reqPromptTokens int) time.Duration {
	ttftMs := ttftMsFromSnapshot(snap, reqPromptTokens)
	if ttftMs <= 0 || math.IsNaN(ttftMs) || math.IsInf(ttftMs, 0) {
		return 0
	}
	return time.Duration(ttftMs * float64(time.Millisecond))
}

// ttftMsFromSnapshot returns the estimated time-to-first-token in milliseconds
// for a candidate/provider snapshot. It is shared between the preflight
// (QuickCapacityCheckWithTTFTForRequest) and the scheduler
// (buildCandidateWithReason) so the two paths cannot drift on what "TTFT"
// means.
//
// Token-budget fields are admission/memory reservations, not decode work that
// must fully drain before this request can emit a first token. Continuous
// batching lets a newly-admitted request join the decode loop once its prefill
// completes; existing active max-output reservations only slow the next decode
// step, which is already reflected by effectiveTPS. Count waiting prefills ahead
// and this request's own prefill instead of treating active_token_budget_used as
// a serial decode backlog.
func ttftMsFromSnapshot(snap routingSnapshot, reqPromptTokens int) float64 {
	if !snap.hasBackendCapacity {
		return 0
	}
	statePenalty, _ := slotStatePenalty(snap.slotState)
	if reqPromptTokens < 0 {
		reqPromptTokens = 0
	}
	prefillTPS := resolvePrefillTPS(snap)
	if prefillTPS <= 0 {
		prefillTPS = 1.0
	}
	effectiveTPS := resolveEffectiveTPS(snap)
	if effectiveTPS <= 0 {
		effectiveTPS = 1.0
	}

	queuedPrefillMs := queuedPrefillTokensAhead(snap, reqPromptTokens) / prefillTPS * 1000.0
	thisPrefillMs := float64(reqPromptTokens) / prefillTPS * 1000.0
	firstDecodeMs := 1000.0 / effectiveTPS
	return statePenalty + queuedPrefillMs + thisPrefillMs + firstDecodeMs
}

func queuedPrefillTokensAhead(snap routingSnapshot, reqPromptTokens int) float64 {
	if reqPromptTokens <= 0 {
		return 0
	}
	waiting := snap.backendWaiting
	reflected := snap.backendRunning + snap.backendWaiting
	if extraPending := snap.pendingForModel - reflected; extraPending > 0 {
		waiting += extraPending
	}
	if waiting <= 0 {
		return 0
	}
	return float64(waiting * reqPromptTokens)
}

func slotStatePenalty(state string) (float64, bool) {
	switch state {
	case "", "running", "idle":
		return slotStatePenaltyRunning, true
	case "unknown":
		// Model is available but not loaded. The provider must evict the
		// current model and load this one — typically 15–60 seconds for
		// large models (depends on model size and disk speed). Warm
		// providers are strongly preferred but cold providers are still
		// eligible when no warm alternative exists.
		return slotStatePenaltyUnknown, true
	case "idle_shutdown":
		return slotStatePenaltyIdleShutdown, true
	case "reloading", "crashed":
		return math.Inf(1), false
	default:
		return slotStatePenaltyUnknown, true
	}
}

func slotStateModelLoaded(state string) bool {
	return state == "running" || state == "idle"
}

func backlogTokenMs(maxTokensPotential int64, waitingTokens, unaccountedPendingTokens, decodeTPS float64) float64 {
	if decodeTPS <= 0 {
		decodeTPS = 1.0
	}
	totalTokensAhead := float64(maxTokensPotential) + waitingTokens + unaccountedPendingTokens
	if totalTokensAhead < 0 {
		totalTokensAhead = 0
	}
	return totalTokensAhead / decodeTPS * 1000.0
}

func healthPenaltyMs(m protocol.SystemMetrics, gpuActiveGB, totalMemGB float64) float64 {
	penalty := m.MemoryPressure*memoryPressurePenaltyMs + m.CPUUsage*cpuUsagePenaltyMs
	switch m.ThermalState {
	case "fair":
		penalty += thermalPenaltyFairMs
	case "serious":
		penalty += thermalPenaltySeriousMs
	}
	if totalMemGB > 0 {
		gpuUtil := gpuActiveGB / totalMemGB
		if gpuUtil < 0 {
			gpuUtil = 0
		}
		if gpuUtil > 1 {
			gpuUtil = 1
		}
		penalty += gpuUtil * gpuUtilizationPenaltyMs
	}
	return penalty
}

// resolveEffectiveTPS returns the best available decode TPS estimate.
// Fallback chain: observed EWMA → fleet median → load-scaled benchmark.
func resolveEffectiveTPS(snap routingSnapshot) float64 {
	if snap.observedDecodeTPS > 0 {
		return snap.observedDecodeTPS
	}
	if snap.fleetMedianTPS > 0 {
		return snap.fleetMedianTPS
	}
	return effectiveDecodeTPS(snap.decodeTPS, snap.backendRunning)
}

// effectiveDecodeTPS scales the static decode TPS down by current
// backend batch size. Returns the static value when the load factor is
// disabled or batch is unknown. Floored at 1 token/s to avoid divide-
// by-zero.
//
// Note on the floor + large reqMax: when effectiveTPS bottoms out, the
// per-request decode cost (reqMax / effectiveTPS * 1000) can become
// very large for big reqMax values. This is intentional — a saturated
// provider should look strictly worse than less-saturated peers — and
// the maxConcurrency gate in snapshotProviderLocked already prevents
// us from getting here when batchSize exceeds the per-tier cap.
func effectiveDecodeTPS(staticTPS float64, backendRunning int) float64 {
	if staticTPS <= 0 {
		return 1.0
	}
	if effectiveTPSLoadFactor <= 0 || backendRunning <= 0 {
		return staticTPS
	}
	tps := staticTPS / (1.0 + effectiveTPSLoadFactor*float64(backendRunning))
	if tps < 1.0 {
		tps = 1.0
	}
	return tps
}

func resolvedDecodeTPS(p *Provider) float64 {
	if p.DecodeTPS > 0 {
		return p.DecodeTPS
	}
	bw := float64(p.Hardware.MemoryBandwidthGBs)
	if bw > 0 {
		return math.Sqrt(bw)
	}
	return 1.0
}

// defaultPrefillToDecodeRatio is the fallback multiplier applied to a provider's
// decode TPS to estimate its prefill TPS when the provider does not report a
// measured prefill rate (prefill_tps). Apple-Silicon MLX prefills the prompt in
// large parallel batches, so prefill throughput is roughly an order of magnitude
// above decode throughput. The historical 4x was far too conservative: combined
// with the 5s+1ms/token TTFT deadline it estimated ~100 tok/s prefill (vs the
// ~1000 tok/s the deadline implicitly assumes), so the TTFT gate wrongly
// rejected warm, capable providers on any prompt above ~550 tokens. No provider
// currently reports prefill_tps, so this fallback is the production path.
const defaultPrefillToDecodeRatio = 12.0

// prefillToDecodeRatio is configured once at startup (via SetPrefillToDecodeRatio,
// e.g. from EIGENINFERENCE_PREFILL_DECODE_RATIO) before the server begins
// serving, then only read on routing paths.
var prefillToDecodeRatio = defaultPrefillToDecodeRatio

// SetPrefillToDecodeRatio overrides the decode→prefill fallback multiplier.
// Values <= 0 are ignored. Must be called before serving starts (read-only after).
func SetPrefillToDecodeRatio(ratio float64) {
	if ratio > 0 {
		prefillToDecodeRatio = ratio
	}
}

func resolvedPrefillTPS(p *Provider) float64 {
	if p.PrefillTPS > 0 {
		return p.PrefillTPS
	}
	return resolvedDecodeTPS(p) * prefillToDecodeRatio
}

func providerModelIDs(p *Provider) []string {
	if p == nil {
		return nil
	}
	// p.Models is replaced (copy-on-write) by UpdateModelWeightHashes when a
	// challenge response carries refreshed weight hashes, so the slice header
	// must be read under p.mu. All callers invoke this helper after releasing
	// p.mu (verified: Heartbeat, RecordChallengeSuccess, SetProviderIdle,
	// DrainQueuedRequestsForProvider), so taking the lock here cannot deadlock.
	p.mu.Lock()
	defer p.mu.Unlock()
	ids := make([]string, 0, len(p.Models))
	for _, m := range p.Models {
		ids = append(ids, m.ID)
	}
	return ids
}

// resolvePrefillTPS returns the best available prefill TPS estimate for TTFT.
// Fallback chain: measured per-slot observed prefill EWMA → snap.prefillTPS (the
// resolvedPrefillTPS chain: registration benchmark → decode×prefillToDecodeRatio
// ×12 fallback). This mirrors how resolveEffectiveTPS prefers the measured
// decode rate over the static estimate. The result is clamped to maxPrefillTPS
// so a single outlier heartbeat cannot collapse the TTFT estimate.
//
// observedPrefillTPS stays 0 until providers ship the W1 measurement, so on
// today's fleet this is a no-op that returns the existing ×12-chain value.
func resolvePrefillTPS(snap routingSnapshot) float64 {
	tps := snap.prefillTPS
	if snap.observedPrefillTPS > 0 {
		tps = snap.observedPrefillTPS
	}
	if tps > maxPrefillTPS {
		tps = maxPrefillTPS
	}
	return tps
}

// PrefillToDecodeRatio returns the current decode→prefill fallback multiplier
// (the value used by resolvedPrefillTPS when a provider does not report a
// measured prefill rate). Exposed for the routing simulation harness.
func PrefillToDecodeRatio() float64 {
	return prefillToDecodeRatio
}

// projectedPerRequestDecodeTPS estimates the decode tokens/sec a NEWLY admitted
// request would receive on this snapshot's provider once it joins the batch
// (backendRunning+1 concurrent). Continuous batching is memory-bandwidth bound,
// so per-request decode degrades with batch size by the same effectiveTPSLoadFactor
// model used elsewhere: rate(b) = solo / (1 + k·b). The measured observed decode
// rate (when present) is unwound from the current batch to a solo rate and then
// reapplied at b+1; otherwise the static benchmark is the solo proxy. Used by the
// decode-floor quality preference (PendingRequest.MinDecodeTPS).
func projectedPerRequestDecodeTPS(snap routingSnapshot) float64 {
	k := effectiveTPSLoadFactor
	if k < 0 {
		k = 0
	}
	b := snap.backendRunning
	if b < 0 {
		b = 0
	}
	solo := snap.decodeTPS
	if snap.observedDecodeTPS > 0 {
		solo = snap.observedDecodeTPS * (1 + k*float64(b)) // unwind measured@b to solo (b=0)
	}
	if solo <= 0 {
		return 0
	}
	return solo / (1 + k*float64(b+1))
}
