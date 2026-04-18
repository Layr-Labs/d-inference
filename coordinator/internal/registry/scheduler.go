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

	queueDepthPenaltyMs      = 1_000.0
	totalPendingPenaltyMs    = 250.0
	memoryPressurePenaltyMs  = 4_000.0
	cpuUsagePenaltyMs        = 1_500.0
	gpuUtilizationPenaltyMs  = 5_000.0
	thermalPenaltyFairMs     = 2_000.0
	thermalPenaltySeriousMs  = 8_000.0
	nearTieCostWindowMs      = 750.0
	challengeFreshnessMaxAge = 6 * time.Minute

	// Backend slot states reported by provider heartbeats.
	slotStateCrashed      = "crashed"
	slotStateIdleShutdown = "idle_shutdown"
	slotStateReloading    = "reloading"

	// Thermal states from system metrics.
	thermalStateFair = "fair"
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
}

type routingCandidate struct {
	provider       *Provider
	snapshot       routingSnapshot
	costMs         float64
	effectiveQueue int
}

// ReserveProvider selects a hardware-routable provider for the request and
// atomically reserves capacity by registering the request in the provider's
// pending set before returning.
func (r *Registry) ReserveProvider(model string, pr *PendingRequest, excludeIDs ...string) *Provider {
	if pr == nil {
		return nil
	}
	if pr.RequestID == "" {
		return nil
	}
	if pr.Model == "" {
		pr.Model = model
	}
	if pr.RequestedMaxTokens <= 0 {
		pr.RequestedMaxTokens = defaultRequestedMaxTokens
	}

	r.mu.Lock()
	defer r.mu.Unlock()

	selected := r.selectBestCandidateLocked(model, pr, excludeIDs...)
	if selected == nil {
		return nil
	}

	p := selected.provider
	p.mu.Lock()
	defer p.mu.Unlock()

	// Re-check capacity under the provider lock in case another goroutine
	// changed the pending set between snapshot and reservation.
	if !r.providerCanAdmitLocked(p, model) {
		return nil
	}

	pr.ProviderID = p.ID
	p.addPendingLocked(pr)
	if p.Status != StatusUntrusted && p.Status != StatusOffline {
		p.Status = StatusServing
	}
	return p
}

func (r *Registry) selectBestCandidateLocked(model string, pr *PendingRequest, excludeIDs ...string) *routingCandidate {
	excludeSet := make(map[string]struct{}, len(excludeIDs))
	for _, id := range excludeIDs {
		excludeSet[id] = struct{}{}
	}

	var best *routingCandidate
	var nearTies []*routingCandidate
	for _, p := range r.providers {
		if _, excluded := excludeSet[p.ID]; excluded {
			continue
		}
		snap, ok := r.snapshotProviderLocked(p, model)
		if !ok {
			continue
		}
		candidate, ok := r.buildCandidate(snap, pr)
		if !ok {
			continue
		}

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
		return nil
	}
	if len(nearTies) == 1 {
		return best
	}

	return breakNearTies(nearTies)
}

// breakNearTies selects the best candidate from a set of near-tied
// candidates using queue-depth, pending count, and random tie-breaking.
func breakNearTies(nearTies []*routingCandidate) *routingCandidate {
	best := nearTies[0]
	for _, c := range nearTies[1:] {
		if c.effectiveQueue < best.effectiveQueue {
			best = c
			continue
		}
		if c.effectiveQueue == best.effectiveQueue && c.snapshot.totalPending < best.snapshot.totalPending {
			best = c
		}
	}

	equivalent := make([]*routingCandidate, 0, len(nearTies))
	for _, c := range nearTies {
		if c.effectiveQueue == best.effectiveQueue &&
			c.snapshot.totalPending == best.snapshot.totalPending &&
			math.Abs(c.costMs-best.costMs) <= nearTieCostWindowMs {
			equivalent = append(equivalent, c)
		}
	}
	if len(equivalent) > 1 {
		return equivalent[rand.Intn(len(equivalent))] //nolint:gosec // non-crypto random for load balancing
	}
	return best
}

// providerRoutableUnderLock checks basic routing eligibility for a provider
// whose mutex is already held. Returns false if the provider should be skipped.
func (r *Registry) providerRoutableUnderLock(p *Provider, model string, now time.Time) bool {
	if !providerServesModelLocked(p, model) {
		return false
	}
	if p.Status == StatusOffline || p.Status == StatusUntrusted {
		return false
	}
	if trustRank(p.TrustLevel) < trustRank(r.MinTrustLevel) {
		return false
	}
	if !p.RuntimeVerified {
		return false
	}
	if p.LastChallengeVerified.IsZero() || now.Sub(p.LastChallengeVerified) > challengeFreshnessMaxAge {
		return false
	}
	return p.pendingCount() < p.maxConcurrency()
}

func (r *Registry) snapshotProviderLocked(p *Provider, model string) (routingSnapshot, bool) {
	now := time.Now()

	p.mu.Lock()
	defer p.mu.Unlock()

	if !r.providerRoutableUnderLock(p, model, now) {
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

	return snap, true
}

func (r *Registry) buildCandidate(snap routingSnapshot, pr *PendingRequest) (*routingCandidate, bool) {
	statePenalty, eligible := slotStatePenalty(snap.slotState)
	if !eligible {
		return nil, false
	}

	if snap.systemMetrics.ThermalState == "critical" {
		return nil, false
	}

	effectiveQueue := snap.pendingForModel
	backendDepth := snap.backendRunning + snap.backendWaiting
	if backendDepth > effectiveQueue {
		effectiveQueue = backendDepth
	}

	reqMax := pr.RequestedMaxTokens
	if reqMax <= 0 {
		reqMax = defaultRequestedMaxTokens
	}
	reqPrompt := pr.EstimatedPromptTokens
	if reqPrompt < 0 {
		reqPrompt = 0
	}

	waitingBacklogTokens := float64(snap.backendWaiting * reqMax)
	unaccountedPendingTokens := float64(snap.pendingMaxTokens) - float64(snap.maxTokensPotential) - waitingBacklogTokens
	if unaccountedPendingTokens < 0 {
		unaccountedPendingTokens = 0
	}

	cost := statePenalty
	cost += float64(effectiveQueue) * queueDepthPenaltyMs
	cost += float64(snap.totalPending) * totalPendingPenaltyMs
	cost += backlogTokenMs(snap.maxTokensPotential, waitingBacklogTokens, unaccountedPendingTokens, snap.decodeTPS)
	cost += float64(reqPrompt)/snap.prefillTPS*1000.0 + float64(reqMax)/snap.decodeTPS*1000.0
	cost += healthPenaltyMs(snap.systemMetrics, snap.gpuMemoryActiveGB, snap.totalMemoryGB)

	return &routingCandidate{
		provider:       snap.provider,
		snapshot:       snap,
		costMs:         cost,
		effectiveQueue: effectiveQueue,
	}, true
}

func slotStatePenalty(state string) (float64, bool) {
	switch state {
	case "", "running":
		return slotStatePenaltyRunning, true
	case "unknown":
		return slotStatePenaltyUnknown, true
	case slotStateIdleShutdown:
		return slotStatePenaltyIdleShutdown, true
	case slotStateReloading, slotStateCrashed:
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
	case thermalStateFair:
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
			case slotStateCrashed, slotStateReloading:
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
			provider := r.ReserveProvider(model, req.Pending)
			if provider == nil {
				r.queue.RequeueFront(req)
				break
			}

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
