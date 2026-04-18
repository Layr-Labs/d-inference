package registry

import (
	"math"
	"math/rand"
	"time"

	"github.com/eigeninference/coordinator/internal/protocol"
)

const (
	// Coordinator-side defaults for request sizing. These are only used for
	// routing heuristics and queue admission, not billing or protocol limits.
	defaultRequestedMaxTokens = 256

	slotStatePenaltyRunning      = 0.0
	slotStatePenaltyUnknown      = 2_500.0
	slotStatePenaltyIdleShutdown = 20_000.0

	// Penalty constants. Phase 3 raised queueDepthPenaltyMs (1000→3000),
	// totalPendingPenaltyMs (250→750), and nearTieCostWindowMs (750→2500).
	// The old values let a fast provider with 1-2 in-flight requests
	// outscore an idle slow provider, because the per-request decode-cost
	// gap (~3-10 s) dwarfed the queue penalty (~1 s/request). The new
	// values make one queued request roughly equivalent to one
	// slow-provider decode, so the cost function actually spreads load
	// across the fleet. Wider tie window admits more candidates to the
	// queue-depth tie-break + random distribution.
	queueDepthPenaltyMs      = 3_000.0
	totalPendingPenaltyMs    = 750.0
	memoryPressurePenaltyMs  = 4_000.0
	cpuUsagePenaltyMs        = 1_500.0
	gpuUtilizationPenaltyMs  = 5_000.0
	thermalPenaltyFairMs     = 2_000.0
	thermalPenaltySeriousMs  = 8_000.0
	nearTieCostWindowMs      = 3_000.0
	challengeFreshnessMaxAge = 6 * time.Minute

	// kvCacheBytesPerToken is a per-token KV-cache size estimate used by
	// the free-memory admission gate. MLX 4-bit attention caches are
	// roughly 0.5 MB/token for 7-8B models; larger models use ~1 MB/token.
	// We use the smaller value as a conservative under-estimate so we
	// don't reject valid placements during the initial rollout. Refine
	// per-architecture later if measured behavior diverges.
	kvCacheBytesPerToken = 524_288 // 0.5 MB
	bytesPerGB           = 1 << 30
)

type routingSnapshot struct {
	provider           *Provider
	model              string
	slotState          string
	totalPending       int
	pendingForModel    int
	pendingMaxTokens   int
	backendRunning     int
	backendWaiting     int
	maxTokensPotential int64
	decodeTPS          float64
	prefillTPS         float64
	systemMetrics      protocol.SystemMetrics
	gpuMemoryActiveGB  float64
	totalMemoryGB      float64
	modelSizeGB        float64 // catalog-reported weight footprint (0 = unknown, gate disabled)
	modelLoaded        bool    // true when the requested model is the currently-running slot
}

type routingCandidate struct {
	provider       *Provider
	snapshot       routingSnapshot
	costMs         float64
	effectiveQueue int
	breakdown      costBreakdown
}

// candidateRejection enumerates why a provider that passed structural
// gates (status, trust, slot state, thermal) was nonetheless excluded
// from selection. Used to populate RoutingDecision counters so callers
// can distinguish "no provider serves this model" from "every fitting
// provider is full".
type candidateRejection int

const (
	rejectNone candidateRejection = iota
	rejectCapacity
)

// costBreakdown decomposes the routing cost so callers can log or
// expose individual contributions. The numeric values match the terms
// added in buildCandidate; total should equal costMs (modulo float
// rounding).
type costBreakdown struct {
	StateMs   float64
	QueueMs   float64
	PendingMs float64
	BacklogMs float64
	ThisReqMs float64
	HealthMs  float64
	Total     float64
}

// RoutingDecision is the public, exportable record of a routing
// selection. Returned by ReserveProviderEx so callers can emit metrics
// and structured logs without reaching into registry internals.
type RoutingDecision struct {
	ProviderID         string  // winning provider, empty if no selection
	Model              string  // requested model
	CostMs             float64 // total cost of the winning candidate
	StateMs            float64 // slot-state penalty contribution
	QueueMs            float64 // pendingForModel × queueDepthPenaltyMs
	PendingMs          float64 // totalPending × totalPendingPenaltyMs
	BacklogMs          float64 // tokens-ahead / decodeTPS contribution
	ThisReqMs          float64 // this request's prefill+decode contribution
	HealthMs           float64 // memory/CPU/thermal/GPU-util contribution
	EffectiveQueue     int     // max(pendingForModel, backendRunning+backendWaiting)
	CandidateCount     int     // total candidates that passed all gates
	CapacityRejections int     // candidates rejected by the free-memory admission gate
}

// ReserveProvider selects a hardware-routable provider for the request and
// atomically reserves capacity by registering the request in the provider's
// pending set before returning.
func (r *Registry) ReserveProvider(model string, pr *PendingRequest, excludeIDs ...string) *Provider {
	p, _ := r.ReserveProviderEx(model, pr, excludeIDs...)
	return p
}

// ReserveProviderEx is the metrics-aware variant of ReserveProvider. It
// returns the same Provider plus a RoutingDecision describing the cost
// breakdown of the winning candidate (or, on selection failure, an
// empty decision with CandidateCount=0). Callers wire the decision into
// Prometheus counters/histograms without the registry needing to import
// the metrics package.
func (r *Registry) ReserveProviderEx(model string, pr *PendingRequest, excludeIDs ...string) (*Provider, RoutingDecision) {
	if pr == nil || pr.RequestID == "" {
		return nil, RoutingDecision{Model: model}
	}
	if pr.Model == "" {
		pr.Model = model
	}
	if pr.RequestedMaxTokens <= 0 {
		pr.RequestedMaxTokens = defaultRequestedMaxTokens
	}

	r.mu.Lock()
	defer r.mu.Unlock()

	selected, candidateCount, capacityRejections := r.selectBestCandidateLockedFull(model, pr, excludeIDs...)
	if selected == nil {
		return nil, RoutingDecision{
			Model:              model,
			CandidateCount:     candidateCount,
			CapacityRejections: capacityRejections,
		}
	}

	p := selected.provider
	p.mu.Lock()
	defer p.mu.Unlock()

	// Re-check capacity under the provider lock in case another goroutine
	// changed the pending set between snapshot and reservation.
	if !r.providerCanAdmitLocked(p, model) {
		return nil, RoutingDecision{
			Model:              model,
			CandidateCount:     candidateCount,
			CapacityRejections: capacityRejections,
		}
	}

	pr.ProviderID = p.ID
	p.addPendingLocked(pr)
	if p.Status != StatusUntrusted && p.Status != StatusOffline {
		p.Status = StatusServing
	}

	bd := selected.breakdown
	decision := RoutingDecision{
		ProviderID:         p.ID,
		Model:              model,
		CostMs:             bd.Total,
		StateMs:            bd.StateMs,
		QueueMs:            bd.QueueMs,
		PendingMs:          bd.PendingMs,
		BacklogMs:          bd.BacklogMs,
		ThisReqMs:          bd.ThisReqMs,
		HealthMs:           bd.HealthMs,
		EffectiveQueue:     selected.effectiveQueue,
		CandidateCount:     candidateCount,
		CapacityRejections: capacityRejections,
	}
	return p, decision
}

func (r *Registry) selectBestCandidateLocked(model string, pr *PendingRequest, excludeIDs ...string) *routingCandidate {
	c, _ := r.selectBestCandidateLockedEx(model, pr, excludeIDs...)
	return c
}

// selectBestCandidateLockedEx is the same selection as
// selectBestCandidateLocked but additionally reports the number of
// eligible candidates evaluated. Used to populate
// RoutingDecision.CandidateCount for metrics/log output.
func (r *Registry) selectBestCandidateLockedEx(model string, pr *PendingRequest, excludeIDs ...string) (*routingCandidate, int) {
	c, _, count := r.selectBestCandidateLockedFull(model, pr, excludeIDs...)
	return c, count
}

// selectBestCandidateLockedFull is the full-fidelity selection that
// also reports how many providers were rejected by capacity-style
// gates (memory). Capacity rejection count lets ReserveProviderEx
// distinguish "no provider serves this model" from "every fitting
// provider is over-subscribed", which is the difference between the
// no_provider and over_capacity outcome counters.
func (r *Registry) selectBestCandidateLockedFull(model string, pr *PendingRequest, excludeIDs ...string) (*routingCandidate, int, int) {
	excludeSet := make(map[string]struct{}, len(excludeIDs))
	for _, id := range excludeIDs {
		excludeSet[id] = struct{}{}
	}

	var best *routingCandidate
	var nearTies []*routingCandidate
	candidateCount := 0
	capacityRejections := 0
	for _, p := range r.providers {
		if _, excluded := excludeSet[p.ID]; excluded {
			continue
		}
		snap, ok := r.snapshotProviderLocked(p, model)
		if !ok {
			continue
		}
		candidate, reason, ok := r.buildCandidateWithReason(snap, pr)
		if !ok {
			if reason == rejectCapacity {
				capacityRejections++
			}
			continue
		}
		candidateCount++

		if best == nil || candidate.costMs < best.costMs {
			best = candidate
			nearTies = []*routingCandidate{candidate}
			continue
		}
		if math.Abs(candidate.costMs-best.costMs) <= nearTieCostWindowMs {
			nearTies = append(nearTies, candidate)
		}
	}

	if best == nil {
		return nil, candidateCount, capacityRejections
	}
	winner := best
	if len(nearTies) > 1 {
		winner = nearTies[0]
		for _, c := range nearTies[1:] {
			if c.effectiveQueue < winner.effectiveQueue {
				winner = c
				continue
			}
			if c.effectiveQueue == winner.effectiveQueue && c.snapshot.totalPending < winner.snapshot.totalPending {
				winner = c
			}
		}

		// If multiple candidates are still equivalent after queue-depth tie-breaks,
		// randomize to avoid burst hot-spotting on a single provider.
		equivalent := make([]*routingCandidate, 0, len(nearTies))
		for _, c := range nearTies {
			if c.effectiveQueue == winner.effectiveQueue &&
				c.snapshot.totalPending == winner.snapshot.totalPending &&
				math.Abs(c.costMs-winner.costMs) <= nearTieCostWindowMs {
				equivalent = append(equivalent, c)
			}
		}
		if len(equivalent) > 1 {
			winner = equivalent[rand.Intn(len(equivalent))]
		}
	}
	r.logRoutingDecision(model, pr, winner, candidateCount)
	return winner, candidateCount, capacityRejections
}

// logRoutingDecision emits a structured debug-level record of the
// winning candidate and its cost breakdown. Cheap when the level is
// disabled, since slog short-circuits before formatting.
func (r *Registry) logRoutingDecision(model string, pr *PendingRequest, winner *routingCandidate, candidates int) {
	if r.logger == nil || winner == nil {
		return
	}
	bd := winner.breakdown
	r.logger.Debug("routing_decision",
		"request_id", pr.RequestID,
		"model", model,
		"winner", winner.provider.ID,
		"cost_ms", bd.Total,
		"state_ms", bd.StateMs,
		"queue_ms", bd.QueueMs,
		"pending_ms", bd.PendingMs,
		"backlog_ms", bd.BacklogMs,
		"this_req_ms", bd.ThisReqMs,
		"health_ms", bd.HealthMs,
		"effective_queue", winner.effectiveQueue,
		"candidates", candidates,
	)
}

func (r *Registry) snapshotProviderLocked(p *Provider, model string) (routingSnapshot, bool) {
	now := time.Now()

	p.mu.Lock()
	defer p.mu.Unlock()

	if !providerServesModelLocked(p, model) {
		return routingSnapshot{}, false
	}
	if p.Status == StatusOffline || p.Status == StatusUntrusted {
		return routingSnapshot{}, false
	}
	if trustRank(p.TrustLevel) < trustRank(r.MinTrustLevel) {
		return routingSnapshot{}, false
	}
	if !p.RuntimeVerified {
		return routingSnapshot{}, false
	}
	if p.LastChallengeVerified.IsZero() || now.Sub(p.LastChallengeVerified) > challengeFreshnessMaxAge {
		return routingSnapshot{}, false
	}
	if p.pendingCount() >= p.maxConcurrency() {
		return routingSnapshot{}, false
	}

	snap := routingSnapshot{
		provider:      p,
		model:         model,
		slotState:     "unknown",
		totalPending:  p.pendingCount(),
		systemMetrics: p.SystemMetrics,
		decodeTPS:     resolvedDecodeTPS(p),
		prefillTPS:    resolvedPrefillTPS(p),
		totalMemoryGB: float64(p.Hardware.MemoryGB),
		modelSizeGB:   r.catalogSizeGBLocked(model),
	}

	for _, pr := range p.pendingReqs {
		if pr.Model != model {
			continue
		}
		snap.pendingForModel++
		maxTok := pr.RequestedMaxTokens
		if maxTok <= 0 {
			maxTok = defaultRequestedMaxTokens
		}
		snap.pendingMaxTokens += maxTok
	}

	if p.BackendCapacity != nil {
		snap.gpuMemoryActiveGB = p.BackendCapacity.GPUMemoryActiveGB
		if p.BackendCapacity.TotalMemoryGB > 0 {
			snap.totalMemoryGB = p.BackendCapacity.TotalMemoryGB
		}
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model != model {
				continue
			}
			snap.slotState = slot.State
			snap.backendRunning = int(slot.NumRunning)
			snap.backendWaiting = int(slot.NumWaiting)
			snap.maxTokensPotential = slot.MaxTokensPotential
			break
		}
	}
	snap.modelLoaded = snap.slotState == "running"

	return snap, true
}

// freeMemoryAdmits returns true when the provider has enough headroom
// to serve the request. Disabled (always true) when the catalog has no
// SizeGB for the model or the provider hasn't reported total memory —
// no signal to gate on. Conservative on the load side: we assume a
// cold provider needs full model + KV cache, while a provider already
// running the model only needs incremental KV space.
func freeMemoryAdmits(snap routingSnapshot, reqPromptTokens, reqMaxTokens int) bool {
	if snap.modelSizeGB <= 0 || snap.totalMemoryGB <= 0 {
		return true
	}
	required := snap.modelSizeGB
	if snap.modelLoaded {
		required = 0 // weights already resident; only KV is incremental
	}
	tokens := reqPromptTokens + reqMaxTokens
	if tokens < 0 {
		tokens = 0
	}
	required += float64(int64(tokens)*kvCacheBytesPerToken) / float64(bytesPerGB)
	free := snap.totalMemoryGB - snap.gpuMemoryActiveGB
	return free >= required
}

func (r *Registry) buildCandidate(snap routingSnapshot, pr *PendingRequest) (*routingCandidate, bool) {
	c, _, ok := r.buildCandidateWithReason(snap, pr)
	return c, ok
}

// buildCandidateWithReason returns the candidate plus, on rejection,
// the reason so callers can split metrics by failure mode.
func (r *Registry) buildCandidateWithReason(snap routingSnapshot, pr *PendingRequest) (*routingCandidate, candidateRejection, bool) {
	statePenalty, eligible := slotStatePenalty(snap.slotState)
	if !eligible {
		return nil, rejectNone, false
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

	queueMs := float64(effectiveQueue) * queueDepthPenaltyMs
	pendingMs := float64(snap.totalPending) * totalPendingPenaltyMs
	backlogMs := backlogTokenMs(snap.maxTokensPotential, waitingBacklogTokens, unaccountedPendingTokens, snap.decodeTPS)
	thisReqMs := float64(reqPrompt)/snap.prefillTPS*1000.0 + float64(reqMax)/snap.decodeTPS*1000.0
	healthMs := healthPenaltyMs(snap.systemMetrics, snap.gpuMemoryActiveGB, snap.totalMemoryGB)
	cost := statePenalty + queueMs + pendingMs + backlogMs + thisReqMs + healthMs

	return &routingCandidate{
		provider:       snap.provider,
		snapshot:       snap,
		costMs:         cost,
		effectiveQueue: effectiveQueue,
		breakdown: costBreakdown{
			StateMs:   statePenalty,
			QueueMs:   queueMs,
			PendingMs: pendingMs,
			BacklogMs: backlogMs,
			ThisReqMs: thisReqMs,
			HealthMs:  healthMs,
			Total:     cost,
		},
	}, rejectNone, true
}

func slotStatePenalty(state string) (float64, bool) {
	switch state {
	case "", "running":
		return slotStatePenaltyRunning, true
	case "unknown":
		return slotStatePenaltyUnknown, true
	case "idle_shutdown":
		return slotStatePenaltyIdleShutdown, true
	case "reloading", "crashed":
		return math.Inf(1), false
	default:
		return slotStatePenaltyUnknown, true
	}
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

func resolvedPrefillTPS(p *Provider) float64 {
	if p.PrefillTPS > 0 {
		return p.PrefillTPS
	}
	return resolvedDecodeTPS(p) * 4.0
}

func providerServesModelLocked(p *Provider, model string) bool {
	for _, m := range p.Models {
		if m.ID == model {
			return true
		}
	}
	return false
}

func providerModelIDs(p *Provider) []string {
	if p == nil {
		return nil
	}
	ids := make([]string, 0, len(p.Models))
	for _, m := range p.Models {
		ids = append(ids, m.ID)
	}
	return ids
}

func (r *Registry) providerCanAdmitLocked(p *Provider, model string) bool {
	if p.Status == StatusOffline || p.Status == StatusUntrusted {
		return false
	}
	if trustRank(p.TrustLevel) < trustRank(r.MinTrustLevel) || !p.RuntimeVerified {
		return false
	}
	if p.LastChallengeVerified.IsZero() || time.Since(p.LastChallengeVerified) > challengeFreshnessMaxAge {
		return false
	}
	if !providerServesModelLocked(p, model) {
		return false
	}
	if p.pendingCount() >= p.maxConcurrency() {
		return false
	}
	if p.BackendCapacity != nil {
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model != model {
				continue
			}
			switch slot.State {
			case "crashed", "reloading":
				return false
			}
			break
		}
	}
	return true
}

func (r *Registry) drainQueuedRequestsForModels(models []string) {
	if r.queue == nil || len(models) == 0 {
		return
	}
	for _, model := range models {
		for {
			req := r.queue.PopNextFresh(model)
			if req == nil {
				break
			}
			if req.Pending == nil {
				req.Pending = &PendingRequest{
					RequestID:          req.RequestID,
					Model:              model,
					RequestedMaxTokens: defaultRequestedMaxTokens,
				}
			}
			provider, decision := r.ReserveProviderEx(model, req.Pending)
			if provider == nil {
				r.queue.RequeueFront(req)
				break
			}
			req.Decision = decision

			select {
			case <-req.Done():
				provider.RemovePending(req.Pending.RequestID)
				r.SetProviderIdle(provider.ID)
				continue
			default:
			}

			select {
			case req.ResponseCh <- provider:
				// Successfully assigned.
			case <-req.Done():
				provider.RemovePending(req.Pending.RequestID)
				r.SetProviderIdle(provider.ID)
				continue
			default:
				provider.RemovePending(req.Pending.RequestID)
				r.SetProviderIdle(provider.ID)
				continue
			}
		}
	}
}
