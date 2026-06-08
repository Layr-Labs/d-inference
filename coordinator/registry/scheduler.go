package registry

import (
	"math"
	"math/rand"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const (
	// Coordinator-side defaults for request sizing. These are only used for
	// routing heuristics and queue admission, not billing or protocol limits.
	defaultRequestedMaxTokens = 256

	slotStatePenaltyRunning      = 0.0
	slotStatePenaltyUnknown      = 30_000.0
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
	hasHeadroom        bool
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
	minRAMGb           int     // catalog authoritative min RAM (GB) to run the model (0 = unknown)
	modelLoaded        bool    // true when the requested model is the currently-running slot
	availableOnDisk    bool    // model is in provider's Models list but not currently loaded

	observedDecodeTPS     float64
	activeTokenBudgetUsed int64
	activeTokenBudgetMax  int64
	queuedTokenBudget     int64
	fleetMedianTPS        float64
}

type routingCandidate struct {
	provider       *Provider
	snapshot       routingSnapshot
	costMs         float64
	effectiveQueue int
	breakdown      costBreakdown
	effectiveTPS   float64 // Phase 4 load-scaled TPS used in this candidate's cost
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
	// rejectModelTooLarge means the model's resident footprint cannot fit in
	// this provider's total memory under any load state. Unlike rejectCapacity
	// (transient "full, retry later") this is permanent for this provider, so
	// it must NOT inflate the busy/429 signal.
	rejectModelTooLarge
)

// modelMemoryHeadroomFactor is the FALLBACK multiple of the on-disk weight size
// used to estimate a model's resident footprint ONLY when the catalog has no
// authoritative min_ram_gb. Prefer min_ram_gb (see modelFitsHardware): a
// synthetic multiple of the raw weight does not match what the operator
// published or what the provider actually loads, and at 2.x it wrongly rejected
// catalog-qualified nodes (e.g. gpt-oss-20b min_ram_gb=24 vs 12.1*2.x>24, and
// gemma-4-26b min_ram_gb=36 vs 28*2.x rejecting the whole 64 GB tier).
const modelMemoryHeadroomFactor = 2.0

// modelFitsHardware reports whether a model can run on a node with the given
// total unified memory (GB). It prefers the catalog's authoritative min_ram_gb
// (the operator-published requirement) and only falls back to a heuristic
// multiple of the on-disk weight size when min_ram_gb is unknown. Fails OPEN
// when nothing is known. The provider still performs the final precise check at
// load time; this gate only filters models that clearly cannot fit per the
// catalog's own contract.
func modelFitsHardware(minRAMGb int, modelSizeGB, totalMemoryGB float64) bool {
	if totalMemoryGB <= 0 {
		return true
	}
	if minRAMGb > 0 {
		return float64(minRAMGb) <= totalMemoryGB
	}
	if modelSizeGB > 0 {
		return modelSizeGB*modelMemoryHeadroomFactor <= totalMemoryGB
	}
	return true
}

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
	CapacityRejections int     // candidates rejected by the free-memory admission gate (transient: full)
	// ModelTooLargeRejections counts providers that serve the model but whose
	// total memory can never fit it (permanent). Kept separate from
	// CapacityRejections so callers don't emit a 429/"over capacity, retry"
	// signal for a model that will never fit anywhere of this size.
	ModelTooLargeRejections int
	EffectiveTPS            float64 // load-scaled decode TPS used in cost (Phase 4)
	StaticTPS               float64 // benchmarked decode TPS before load scaling
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

	selected, candidateCount, capacityRejections, tooLargeRejections := r.selectBestCandidateLockedFull(model, pr, excludeIDs...)
	if selected == nil {
		return nil, RoutingDecision{
			Model:                   model,
			CandidateCount:          candidateCount,
			CapacityRejections:      capacityRejections,
			ModelTooLargeRejections: tooLargeRejections,
		}
	}

	p := selected.provider
	p.mu.Lock()
	defer p.mu.Unlock()

	// Re-check capacity under the provider lock in case another goroutine
	// changed the pending set between snapshot and reservation. relaxTrust
	// mirrors selection: the trust floor (and private-only admission) is relaxed
	// only when this is the caller's own machine — for exclusive self-route
	// (always owned here) or for prefer when the winner happens to be owned.
	owned := p.AccountID != "" && p.AccountID == pr.OwnerAccountID
	relaxTrust := pr.SelfRouteOnly || (pr.PreferOwner && owned)
	if !r.providerCanAdmitLocked(p, model, relaxTrust) {
		return nil, RoutingDecision{
			Model:                   model,
			CandidateCount:          candidateCount,
			CapacityRejections:      capacityRejections,
			ModelTooLargeRejections: tooLargeRejections,
		}
	}

	pr.ProviderID = p.ID
	p.addPendingLocked(pr)
	if p.Status != StatusUntrusted && p.Status != StatusOffline {
		p.Status = StatusServing
	}

	bd := selected.breakdown
	decision := RoutingDecision{
		ProviderID:              p.ID,
		Model:                   model,
		CostMs:                  bd.Total,
		StateMs:                 bd.StateMs,
		QueueMs:                 bd.QueueMs,
		PendingMs:               bd.PendingMs,
		BacklogMs:               bd.BacklogMs,
		ThisReqMs:               bd.ThisReqMs,
		HealthMs:                bd.HealthMs,
		EffectiveQueue:          selected.effectiveQueue,
		CandidateCount:          candidateCount,
		CapacityRejections:      capacityRejections,
		ModelTooLargeRejections: tooLargeRejections,
		EffectiveTPS:            selected.effectiveTPS,
		StaticTPS:               selected.snapshot.decodeTPS,
	}
	return p, decision
}

// selectBestCandidateLockedFull is the full-fidelity selection that
// also reports how many providers were rejected by capacity-style
// gates (memory). Capacity rejection count lets ReserveProviderEx
// distinguish "no provider serves this model" from "every fitting
// provider is over-subscribed", which is the difference between the
// no_provider and over_capacity outcome counters.
func (r *Registry) selectBestCandidateLockedFull(model string, pr *PendingRequest, excludeIDs ...string) (*routingCandidate, int, int, int) {
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
	tooLargeRejections := 0
	for _, p := range r.providers {
		owned := providerOwnedBy(p, pr.OwnerAccountID)
		// Exclusive self-route: restrict to the caller's own machines and never
		// fall back to the public fleet.
		if pr.SelfRouteOnly && !owned {
			continue
		}
		if len(allowedSerials) > 0 {
			if !providerMatchesAllowedSerial(p, allowedSerials) {
				continue
			}
		}
		if _, excluded := excludeSet[p.ID]; excluded {
			continue
		}
		// Relax the hardware-trust floor ONLY for the caller's own (possibly
		// un-enrolled) machine — whether exclusive self-route or prefer — never
		// for public providers.
		relaxTrust := owned && (pr.SelfRouteOnly || pr.PreferOwner)
		snap, ok := r.snapshotProviderLocked(p, model, relaxTrust)
		if !ok {
			continue
		}
		candidate, reason, ok := r.buildCandidateWithReason(snap, pr)
		if !ok {
			switch reason {
			case rejectCapacity:
				capacityRejections++
			case rejectModelTooLarge:
				tooLargeRejections++
			}
			continue
		}
		candidates = append(candidates, candidate)
		candidateCount++
	}

	if len(candidates) == 0 {
		return nil, candidateCount, capacityRejections, tooLargeRejections
	}

	// Prefer-with-fallback: if the caller asked to prefer their own machine and
	// at least one owned candidate can serve, choose among owned candidates
	// only; otherwise fall back to the full pool (a public provider, charged
	// normally). Exclusive self-route already filtered to owned above.
	pool := candidates
	if pr.PreferOwner {
		owned := make([]*routingCandidate, 0, len(candidates))
		for _, c := range candidates {
			if providerOwnedBy(c.provider, pr.OwnerAccountID) {
				owned = append(owned, c)
			}
		}
		if len(owned) > 0 {
			pool = owned
		}
	}

	var best *routingCandidate
	for _, c := range pool {
		if best == nil || c.costMs < best.costMs {
			best = c
		}
	}
	nearTies := make([]*routingCandidate, 0, len(pool))
	for _, c := range pool {
		if math.Abs(c.costMs-best.costMs) <= nearTieCostWindowMs {
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
				math.Abs(c.costMs-winner.costMs) <= nearTieCostWindowMs {
				equivalent = append(equivalent, c)
			}
		}
		if len(equivalent) > 1 {
			winner = equivalent[rand.Intn(len(equivalent))]
		}
	}
	r.logRoutingDecision(model, pr, winner, candidateCount)
	return winner, candidateCount, capacityRejections, tooLargeRejections
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

// providerOwnedBy reports whether p is owned by accountID. Ownership is the
// coordinator-stamped Provider.AccountID (set at registration from the device
// auth token), never a client-supplied value — so it cannot be forged by a
// caller. An empty accountID never matches.
func providerOwnedBy(p *Provider, accountID string) bool {
	if p == nil || accountID == "" {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.AccountID != "" && p.AccountID == accountID
}

// OwnedProviderSummary reports, for the given account, how many of its
// currently-connected providers are online and how many can serve `model`.
// It powers self-route pre-flight error messaging: distinguishing "your
// machine is offline" from "your machine can't serve this model". The
// model-serving check applies the same privacy/runtime/challenge gates as
// routing but deliberately ignores the hardware-trust gate, which self-route
// relaxes for a caller's own machine. "Linked but offline" providers are not
// counted here (they are not in the registry); callers detect zero linked
// machines via store.ListProvidersByAccount.
func (r *Registry) OwnedProviderSummary(accountID, model string) (online, servesModel int) {
	if accountID == "" {
		return 0, 0
	}
	now := time.Now()
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		p.mu.Lock()
		if p.AccountID == "" || p.AccountID != accountID {
			p.mu.Unlock()
			continue
		}
		if p.Status == StatusOffline || p.Status == StatusUntrusted {
			p.mu.Unlock()
			continue
		}
		online++
		serves := r.providerServesCatalogModelLocked(p, model) &&
			p.RuntimeVerified &&
			providerSupportsPrivateTextLocked(p) &&
			!p.LastChallengeVerified.IsZero() &&
			now.Sub(p.LastChallengeVerified) <= challengeFreshnessMaxAge
		p.mu.Unlock()
		if serves {
			servesModel++
		}
	}
	return online, servesModel
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
		"effective_tps", winner.effectiveTPS,
		"effective_queue", winner.effectiveQueue,
		"candidates", candidates,
	)
}

// snapshotProviderLocked builds a routing snapshot for p, returning ok=false
// when p fails any structural/privacy/capacity gate. selfRouteOwner is true
// when this is a self-route request and p is owned by the requesting account.
// It (1) drops the hardware-trust floor to TrustNone — a personal Mac will not
// be MDM/MDA enrolled, so without this it would be unroutable to its own owner
// — and (2) admits a private-only machine, which is otherwise excluded from
// the public fleet. Every privacy-critical gate (RuntimeVerified, private-text
// support, challenge freshness) still applies, so plaintext is never exposed
// and only the genuinely-signed provider binary serves.
func (r *Registry) snapshotProviderLocked(p *Provider, model string, selfRouteOwner bool) (routingSnapshot, bool) {
	now := time.Now()

	p.mu.Lock()
	defer p.mu.Unlock()

	if !r.providerServesCatalogModelLocked(p, model) {
		return routingSnapshot{}, false
	}
	if p.Status == StatusOffline || p.Status == StatusUntrusted {
		return routingSnapshot{}, false
	}
	// A private-only machine never serves the public fleet — only its owner's
	// self-route requests.
	if p.PrivateOnly && !selfRouteOwner {
		return routingSnapshot{}, false
	}
	minTrust := r.MinTrustLevel
	if selfRouteOwner {
		minTrust = TrustNone
	}
	if trustRank(p.TrustLevel) < trustRank(minTrust) {
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
		minRAMGb:      r.catalogMinRAMGbLocked(model),
	}

	for _, pr := range p.pendingReqs {
		if pr.Model != model {
			continue
		}
		snap.pendingForModel++
		snap.pendingMaxTokens += pendingTokenBudget(pr)
	}
	snap.hasHeadroom = p.hasConcurrencyHeadroomForModelLocked(model)

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
			snap.observedDecodeTPS = slot.ObservedDecodeTPS
			snap.activeTokenBudgetUsed = slot.ActiveTokenBudgetUsed
			snap.activeTokenBudgetMax = slot.ActiveTokenBudgetMax
			snap.queuedTokenBudget = slot.QueuedTokenBudget
			break
		}
	}
	snap.modelLoaded = snap.slotState == "running"
	snap.availableOnDisk = !snap.modelLoaded
	snap.fleetMedianTPS = r.tpsRegistry.Median(model, p.Hardware.ChipFamily)

	return snap, true
}

// freeMemoryAdmits returns true when the provider has enough headroom.
// Providers that report a token budget use budget-based admission;
// legacy providers fall back to memory-based estimation.
func freeMemoryAdmits(snap routingSnapshot, reqPromptTokens, reqMaxTokens int) bool {
	if snap.activeTokenBudgetMax > 0 {
		requestTokens := int64(reqPromptTokens) + int64(reqMaxTokens)
		// Include coordinator-side pending tokens not yet reflected in the
		// provider's heartbeat. Avoid double-counting active/queued backend
		// budgets that are still present in the coordinator pending set until
		// completion/cancellation removes them.
		coordinatorExtra := int64(snap.pendingMaxTokens) - committedTokenBudget(snap)
		if coordinatorExtra < 0 {
			coordinatorExtra = 0
		}
		return snap.activeTokenBudgetUsed+snap.queuedTokenBudget+coordinatorExtra+requestTokens <= snap.activeTokenBudgetMax
	}

	if snap.modelSizeGB <= 0 || snap.totalMemoryGB <= 0 {
		return true
	}
	required := snap.modelSizeGB
	if snap.modelLoaded {
		required = 0
	}
	tokens := int64(reqPromptTokens) + int64(reqMaxTokens)
	if tokens < 0 {
		tokens = 0
	}
	const maxTokensForCalc = 16 << 20
	if tokens > maxTokensForCalc {
		tokens = maxTokensForCalc
	}
	kvCacheGB := float64(tokens*kvCacheBytesPerToken) / float64(bytesPerGB)
	required += kvCacheGB

	// When the model is available on disk but not currently loaded, the
	// provider will evict idle models to make room (LRU eviction). Check
	// whether the model individually fits in total memory (with OS/KV
	// overhead) rather than requiring it to fit alongside existing loaded
	// models. The provider handles the swap autonomously.
	//
	// However, if the provider has in-flight requests (totalPending > 0),
	// it cannot evict the currently-serving model. In that case, fall
	// through to the standard free-memory check which requires room
	// alongside active models.
	if snap.availableOnDisk && !snap.modelLoaded && snap.totalPending == 0 {
		const osReserveGB = 4.0
		return snap.modelSizeGB+kvCacheGB+osReserveGB <= snap.totalMemoryGB
	}

	free := snap.totalMemoryGB - snap.gpuMemoryActiveGB
	return free >= required
}

func pendingTokenBudget(pr *PendingRequest) int {
	if pr == nil {
		return 0
	}
	prompt := pr.EstimatedPromptTokens
	if prompt < 0 {
		prompt = 0
	}
	maxTok := pr.RequestedMaxTokens
	if maxTok <= 0 {
		maxTok = defaultRequestedMaxTokens
	}
	return prompt + maxTok
}

func committedTokenBudget(snap routingSnapshot) int64 {
	committed := snap.activeTokenBudgetUsed + snap.queuedTokenBudget
	if snap.maxTokensPotential > committed {
		committed = snap.maxTokensPotential
	}
	if committed < 0 {
		return 0
	}
	return committed
}

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
	modelResident := snap.slotState == "running" || snap.slotState == "idle"
	if !modelResident && !modelFitsHardware(snap.minRAMGb, snap.modelSizeGB, snap.totalMemoryGB) {
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
			Total:     cost,
		},
	}, rejectNone, true
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

func resolvedPrefillTPS(p *Provider) float64 {
	if p.PrefillTPS > 0 {
		return p.PrefillTPS
	}
	return resolvedDecodeTPS(p) * 4.0
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

func (r *Registry) providerCanAdmitLocked(p *Provider, model string, selfRouteOwner bool) bool {
	if p.Status == StatusOffline || p.Status == StatusUntrusted {
		return false
	}
	if p.PrivateOnly && !selfRouteOwner {
		return false
	}
	minTrust := r.MinTrustLevel
	if selfRouteOwner {
		minTrust = TrustNone
	}
	if trustRank(p.TrustLevel) < trustRank(minTrust) || !p.RuntimeVerified {
		return false
	}
	if !providerSupportsPrivateTextLocked(p) {
		return false
	}
	if p.LastChallengeVerified.IsZero() || time.Since(p.LastChallengeVerified) > challengeFreshnessMaxAge {
		return false
	}
	if !r.providerServesCatalogModelLocked(p, model) {
		return false
	}
	if !p.hasConcurrencyHeadroomForModelLocked(model) {
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

// QuickCapacityCheck performs a fast, read-only scan of the provider fleet to
// determine whether any provider could serve a request for the given model
// right now. It runs the same gates as the full routing path (status, trust,
// runtime, privacy, challenge freshness, concurrency headroom, slot state,
// free memory) but does NOT reserve capacity or create pending requests.
//
// Returns:
//   - candidateCount: providers that passed ALL gates (could route right now)
//   - capacityRejections: providers that serve the model and passed structural
//     gates but were rejected for capacity reasons (full concurrency, no free
//     memory, etc.)
//
// This is used for the pre-flight 429 check: if candidateCount == 0 &&
// capacityRejections > 0, providers exist but are all at capacity (429).
// If candidateCount == 0 && capacityRejections == 0, no provider serves
// the model at all (404/503).
//
//   - modelTooLarge: providers that serve the model but whose memory can never
//     fit it. Kept separate from capacityRejections so the caller does NOT 429
//     a model that will never fit (the client would retry forever) — it should
//     surface model_too_large / 503 instead.
func (r *Registry) QuickCapacityCheck(model string, estimatedPromptTokens, requestedMaxTokens int, allowedSerials ...string) (candidateCount, capacityRejections, modelTooLarge int) {
	// Use a dummy PendingRequest with the caller's actual token estimates
	// for the admission gate (freeMemoryAdmits).
	if estimatedPromptTokens <= 0 {
		estimatedPromptTokens = 500
	}
	if requestedMaxTokens <= 0 {
		requestedMaxTokens = defaultRequestedMaxTokens
	}
	dummyPR := &PendingRequest{
		RequestID:             "capacity-check",
		Model:                 model,
		EstimatedPromptTokens: estimatedPromptTokens,
		RequestedMaxTokens:    requestedMaxTokens,
	}

	// Build allowed serial set for optional provider filtering.
	allowedSet := make(map[string]struct{}, len(allowedSerials))
	for _, s := range allowedSerials {
		allowedSet[s] = struct{}{}
	}

	r.mu.RLock()
	defer r.mu.RUnlock()

	now := time.Now()
	for _, p := range r.providers {
		// Filter by allowed serials before acquiring the provider lock
		// (providerMatchesAllowedSerial takes p.mu internally).
		if len(allowedSet) > 0 && !providerMatchesAllowedSerial(p, allowedSet) {
			continue
		}

		p.mu.Lock()

		// Structural gates (same as snapshotProviderLocked). This pre-flight
		// only runs for public (non-self-route) requests, so private-only
		// machines are excluded unconditionally.
		if !r.providerServesCatalogModelLocked(p, model) {
			p.mu.Unlock()
			continue
		}
		if p.Status == StatusOffline || p.Status == StatusUntrusted {
			p.mu.Unlock()
			continue
		}
		if p.PrivateOnly {
			p.mu.Unlock()
			continue
		}
		if trustRank(p.TrustLevel) < trustRank(r.MinTrustLevel) {
			p.mu.Unlock()
			continue
		}
		if !p.RuntimeVerified {
			p.mu.Unlock()
			continue
		}
		if !providerSupportsPrivateTextLocked(p) {
			p.mu.Unlock()
			continue
		}
		if p.LastChallengeVerified.IsZero() || now.Sub(p.LastChallengeVerified) > challengeFreshnessMaxAge {
			p.mu.Unlock()
			continue
		}

		// Concurrency gate.
		if !p.hasConcurrencyHeadroomForModelLocked(model) {
			p.mu.Unlock()
			capacityRejections++
			continue
		}

		// Build a snapshot for the admission gate (slot state + free memory).
		snap := routingSnapshot{
			provider:      p,
			model:         model,
			slotState:     "unknown",
			totalPending:  p.pendingCount(),
			totalMemoryGB: float64(p.Hardware.MemoryGB),
			modelSizeGB:   r.catalogSizeGBLocked(model),
			minRAMGb:      r.catalogMinRAMGbLocked(model),
		}
		for _, pending := range p.pendingReqs {
			if pending.Model != model {
				continue
			}
			snap.pendingForModel++
			snap.pendingMaxTokens += pendingTokenBudget(pending)
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
				snap.activeTokenBudgetUsed = slot.ActiveTokenBudgetUsed
				snap.activeTokenBudgetMax = slot.ActiveTokenBudgetMax
				snap.queuedTokenBudget = slot.QueuedTokenBudget
				snap.maxTokensPotential = slot.MaxTokensPotential
				break
			}
		}
		snap.modelLoaded = snap.slotState == "running"
		snap.availableOnDisk = !snap.modelLoaded

		p.mu.Unlock()

		// Absolute hardware-fit gate (mirrors buildCandidateWithReason). A model
		// that can never fit this node is a permanent miss, not transient
		// capacity pressure — count it separately so the caller never 429s it.
		// Skipped for a resident ("running"/"idle") model, which has demonstrably
		// fit.
		modelResident := snap.slotState == "running" || snap.slotState == "idle"
		if !modelResident && !modelFitsHardware(snap.minRAMGb, snap.modelSizeGB, snap.totalMemoryGB) {
			modelTooLarge++
			continue
		}

		// Slot state gate (crashed/reloading are ineligible).
		if _, eligible := slotStatePenalty(snap.slotState); !eligible {
			continue
		}

		// Free memory / token budget admission gate.
		if !freeMemoryAdmits(snap, dummyPR.EstimatedPromptTokens, dummyPR.RequestedMaxTokens) {
			capacityRejections++
			continue
		}

		candidateCount++
	}
	return candidateCount, capacityRejections, modelTooLarge
}

// DrainQueuedRequestsForModel attempts to assign queued requests for a
// single model to available providers. Called when a load_model completes
// so requests don't have to wait for the next heartbeat cycle.
func (r *Registry) DrainQueuedRequestsForModel(model string) {
	r.drainQueuedRequestsForModels([]string{model})
}

// DrainQueuedRequestsForProvider attempts to assign queued requests for every
// model a provider serves. Called when a provider becomes newly eligible for
// routing (e.g. it just passed APNs code-identity attestation) so queued
// demand is satisfied immediately instead of waiting for the next heartbeat.
func (r *Registry) DrainQueuedRequestsForProvider(p *Provider) {
	if p == nil {
		return
	}
	r.drainQueuedRequestsForModels(providerModelIDs(p))
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
