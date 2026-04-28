package registry

import (
	"math"
	"math/rand"
	"time"

	providerpricing "github.com/eigeninference/coordinator/internal/pricing"
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
	// the free-memory admission gate.
	//
	// Measured on M4 Max (Qwen2.5-7B-4bit, prompt≈2330 + completion≈72):
	// 357,615 bytes/token (0.34 MB). Prior default of 0.5 MB was ~47%
	// too conservative — providers were being rejected for "no fit"
	// when they actually had room. Rounded up slightly to 400,000 to
	// leave headroom for larger models (70B class may be ~2x) without
	// re-running the gate per architecture. Refine per-model via
	// catalog metadata once more measurements exist.
	kvCacheBytesPerToken = 400_000 // ~0.38 MB; covers 7-8B with slack
	bytesPerGB           = 1 << 30

	// effectiveTPSLoadFactor controls how aggressively decode TPS
	// degrades as a provider takes on more concurrent requests. The
	// effective TPS used in cost is `decodeTPS / (1 + k * batchSize)`
	// where batchSize is the backend's currently-running request count.
	//
	// Measured on M4 Max (Qwen2.5-7B-4bit) at N=1/2/4/8 concurrent
	// decodes: per-request TPS = 92.8 / 69.5 / 35.9 / 29.6. Median
	// implied k = 0.27 (see scripts/calibrate-routing.sh load-factor).
	// Prior default 0.4 was ~48% too aggressive — it under-predicted
	// per-request TPS at small batch sizes, pushing traffic off the
	// big machines sooner than warranted.
	// Set to 0 to disable load scaling.
	effectiveTPSLoadFactor = 0.27
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
	accountID          string
	providerKey        string
}

type routingCandidate struct {
	provider       *Provider
	snapshot       routingSnapshot
	costMs         float64
	effectiveQueue int
	breakdown      costBreakdown
	effectiveTPS   float64 // Phase 4 load-scaled TPS used in this candidate's cost
	priceMicroUSD  int64
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
	EffectiveTPS       float64 // load-scaled decode TPS used in cost (Phase 4)
	StaticTPS          float64 // benchmarked decode TPS before load scaling
	RoutingPreference  string  // "performance" or "cost"
	EstimatedPrice     int64   // estimated request cost used for cost routing
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
	pr.RoutingPreference = normalizeRoutingPreference(pr.RoutingPreference)
	if pr.RequestedMaxTokens <= 0 {
		pr.RequestedMaxTokens = defaultRequestedMaxTokens
	}

	r.mu.Lock()
	defer r.mu.Unlock()

	selected, candidateCount, capacityRejections := r.selectBestCandidateLockedFull(model, pr, excludeIDs...)
	if selected == nil {
		return nil, RoutingDecision{
			Model:              model,
			RoutingPreference:  pr.RoutingPreference,
			CandidateCount:     candidateCount,
			CapacityRejections: capacityRejections,
		}
	}

	p := selected.provider
	p.mu.Lock()
	defer p.mu.Unlock()

	// Re-check capacity under the provider lock in case another goroutine
	// changed the pending set between snapshot and reservation.
	if !r.providerCanAdmitLocked(p, model, pr) {
		return nil, RoutingDecision{
			Model:              model,
			RoutingPreference:  pr.RoutingPreference,
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
		RoutingPreference:  pr.RoutingPreference,
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
		EffectiveTPS:       selected.effectiveTPS,
		StaticTPS:          selected.snapshot.decodeTPS,
		EstimatedPrice:     selected.priceMicroUSD,
	}
	return p, decision
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
	allowedSerials := make(map[string]struct{}, len(pr.AllowedProviderSerials))
	for _, serial := range pr.AllowedProviderSerials {
		allowedSerials[serial] = struct{}{}
	}

	// Two-pass selection: collect all eligible candidates first, then
	// compute best + tie pool. The single-pass approach was order-
	// dependent — when a new best replaced an older one within the tie
	// window, candidates near the OLD best (and still near the NEW
	// best) were dropped from the pool, making the queue-depth tie-
	// break flaky under map iteration randomness.
	candidates := make([]*routingCandidate, 0, len(r.providers))
	candidateCount := 0
	capacityRejections := 0
	for _, p := range r.providers {
		if len(allowedSerials) > 0 {
			if !providerMatchesAllowedSerial(p, allowedSerials) {
				continue
			}
		}
		if _, excluded := excludeSet[p.ID]; excluded {
			continue
		}
		snap, ok := r.snapshotProviderLocked(p, model, pr)
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
		candidates = append(candidates, candidate)
		candidateCount++
	}

	if len(candidates) == 0 {
		return nil, candidateCount, capacityRejections
	}

	var best *routingCandidate
	for _, c := range candidates {
		if best == nil || candidateLess(c, best, pr.RoutingPreference) {
			best = c
		}
	}
	nearTies := make([]*routingCandidate, 0, len(candidates))
	for _, c := range candidates {
		if nearTie(c, best, pr.RoutingPreference) {
			nearTies = append(nearTies, c)
		}
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
				nearTie(c, winner, pr.RoutingPreference) {
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

func normalizeRoutingPreference(pref string) string {
	switch pref {
	case "cost":
		return "cost"
	default:
		return "performance"
	}
}

func candidateLess(a, b *routingCandidate, pref string) bool {
	if pref == "cost" {
		if a.priceMicroUSD != b.priceMicroUSD {
			return a.priceMicroUSD < b.priceMicroUSD
		}
	}
	return a.costMs < b.costMs
}

func nearTie(a, b *routingCandidate, pref string) bool {
	if pref == "cost" && a.priceMicroUSD != b.priceMicroUSD {
		return false
	}
	return math.Abs(a.costMs-b.costMs) <= nearTieCostWindowMs
}

func providerMatchesAllowedSerial(p *Provider, allowed map[string]struct{}) bool {
	if p == nil || len(allowed) == 0 {
		return true
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.AttestationResult != nil {
		if _, ok := allowed[p.AttestationResult.SerialNumber]; ok && p.AttestationResult.SerialNumber != "" {
			return true
		}
	}
	if p.MDAResult != nil {
		if _, ok := allowed[p.MDAResult.DeviceSerial]; ok && p.MDAResult.DeviceSerial != "" {
			return true
		}
	}
	return false
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
		"routing_preference", pr.RoutingPreference,
		"winner", winner.provider.ID,
		"cost_ms", bd.Total,
		"estimated_price_micro_usd", winner.priceMicroUSD,
		"state_ms", bd.StateMs,
		"queue_ms", bd.QueueMs,
		"pending_ms", bd.PendingMs,
		"backlog_ms", bd.BacklogMs,
		"this_req_ms", bd.ThisReqMs,
		"health_ms", bd.HealthMs,
		"effective_tps", winner.effectiveTPS,
		"effective_queue", winner.effectiveQueue,
		"candidates", candidates,
	)
}

func (r *Registry) snapshotProviderLocked(p *Provider, model string, pr *PendingRequest) (routingSnapshot, bool) {
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
	if !providerSupportsPrivateTextLocked(p) {
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
		accountID:     p.AccountID,
		providerKey:   pricingProviderKeyLocked(p),
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
	tokens := int64(reqPromptTokens) + int64(reqMaxTokens)
	if tokens < 0 {
		tokens = 0
	}
	// Defensive cap on token count for the KV calc. Realistic prompts top
	// out around 1 M tokens on the largest context windows (Gemini-class);
	// 16 M leaves comfortable slack for synthetic/abusive inputs without
	// risking int64 overflow when multiplied by kvCacheBytesPerToken
	// (16 M × 0.5 MB = 8 TB, comfortably under int64 max).
	const maxTokensForCalc = 16 << 20
	if tokens > maxTokensForCalc {
		tokens = maxTokensForCalc
	}
	required += float64(tokens*kvCacheBytesPerToken) / float64(bytesPerGB)
	free := snap.totalMemoryGB - snap.gpuMemoryActiveGB
	return free >= required
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

	// Phase 4: load-scale decode TPS by current backend batch size.
	// Static benchmarked TPS represents batch=1 throughput, but real
	// per-request TPS degrades as the backend takes on more concurrent
	// decodes. Using the load-adjusted value in cost makes a heavily
	// batched fast provider effectively as slow as an idle slow one,
	// which is the actual user-perceived behavior.
	effectiveTPS := effectiveDecodeTPS(snap.decodeTPS, snap.backendRunning)

	queueMs := float64(effectiveQueue) * queueDepthPenaltyMs
	pendingMs := float64(snap.totalPending) * totalPendingPenaltyMs
	backlogMs := backlogTokenMs(snap.maxTokensPotential, waitingBacklogTokens, unaccountedPendingTokens, effectiveTPS)
	thisReqMs := float64(reqPrompt)/snap.prefillTPS*1000.0 + float64(reqMax)/effectiveTPS*1000.0
	healthMs := healthPenaltyMs(snap.systemMetrics, snap.gpuMemoryActiveGB, snap.totalMemoryGB)
	cost := statePenalty + queueMs + pendingMs + backlogMs + thisReqMs + healthMs
	priceMicroUSD := providerpricing.CalculateCost(r.store, snap.accountID, snap.providerKey, snap.model, reqPrompt, reqMax)

	return &routingCandidate{
		provider:       snap.provider,
		snapshot:       snap,
		costMs:         cost,
		effectiveQueue: effectiveQueue,
		effectiveTPS:   effectiveTPS,
		priceMicroUSD:  priceMicroUSD,
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

func pricingProviderKeyLocked(p *Provider) string {
	if p.AttestationResult != nil {
		if p.AttestationResult.SerialNumber != "" {
			return p.AttestationResult.SerialNumber
		}
		if p.AttestationResult.PublicKey != "" {
			return p.AttestationResult.PublicKey
		}
	}
	if p.PublicKey != "" {
		return p.PublicKey
	}
	return p.ID
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

func (r *Registry) providerCanAdmitLocked(p *Provider, model string, pr *PendingRequest) bool {
	if p.Status == StatusOffline || p.Status == StatusUntrusted {
		return false
	}
	if trustRank(p.TrustLevel) < trustRank(r.MinTrustLevel) || !p.RuntimeVerified {
		return false
	}
	if !providerSupportsPrivateTextLocked(p) {
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
		var skipped []*QueuedRequest
		requeueSkipped := func() {
			for i := len(skipped) - 1; i >= 0; i-- {
				r.queue.RequeueFront(skipped[i])
			}
			skipped = nil
		}
		for {
			req := r.queue.PopNextFresh(model)
			if req == nil {
				requeueSkipped()
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
				skipped = append(skipped, req)
				continue
			}
			req.Decision = decision
			requeueSkipped()

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
