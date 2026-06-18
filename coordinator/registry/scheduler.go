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
	challengeFreshnessMaxAge = 16 * time.Minute

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
	// freeForLoadGB is the provider-reported max additional model-weight (GB) it
	// can load right now (net of cap/reserve/headroom, idle models reclaimed).
	// When non-nil it is the authoritative cold-load gate; nil = legacy provider
	// (fall back to the total-memory heuristic). See protocol.BackendCapacity.
	freeForLoadGB   *float64
	modelSizeGB     float64 // catalog-reported weight footprint (0 = unknown, gate disabled)
	minRAMGb        int     // catalog authoritative min RAM (GB) to run the model (0 = unknown)
	modelLoaded     bool    // true when the requested model is resident (running or idle)
	availableOnDisk bool    // model is in provider's Models list but not currently loaded

	observedDecodeTPS     float64
	observedPrefillTPS    float64 // measured per-slot prefill EWMA; 0 = unreported (fall back to prefillTPS chain)
	activeTokenBudgetUsed int64
	activeTokenBudgetMax  int64
	queuedTokenBudget     int64
	fleetMedianTPS        float64
	hasBackendCapacity    bool // provider reports BackendCapacity; TTFT estimates are reliable
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
	// rejectVisionUnsupported means the request carries image/video input but
	// this provider only advertises a text-only build of the model. Permanent for
	// this provider (until it loads a VLM build), so like rejectModelTooLarge it
	// must NOT inflate the transient busy/429 signal.
	rejectVisionUnsupported
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
	TTFTMs    float64 // estimated time-to-first-token for this candidate
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
	// VisionRejections counts providers that serve the model but only as a
	// text-only build, when the request requires vision. Lets the caller return a
	// precise "no vision-capable provider for this model" error instead of a
	// generic capacity/queue signal.
	VisionRejections int
	// TTFTRejections counts providers that passed all other gates but exceeded
	// the per-request MaxTTFTMs ceiling. Lets the caller fail fast with a 429
	// instead of queueing or routing to a provider that misses the SLA.
	TTFTRejections int
	EffectiveTPS   float64 // load-scaled decode TPS used in cost (Phase 4)
	StaticTPS      float64 // benchmarked decode TPS before load scaling
	// BestTTFTMs is the lowest TTFT estimate seen during selection, even if it
	// exceeded MaxTTFTMs. Used to compute an accurate Retry-After when all
	// candidates are too slow.
	BestTTFTMs float64
	// TTFTMs is the estimated time-to-first-token of the selected provider.
	TTFTMs float64
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

	selected, candidateCount, capacityRejections, tooLargeRejections, visionRejections, ttftRejections, bestTTFTMs := r.selectBestCandidateLockedFull(model, pr, excludeIDs...)
	if selected == nil {
		return nil, RoutingDecision{
			Model:                   model,
			CandidateCount:          candidateCount,
			CapacityRejections:      capacityRejections,
			ModelTooLargeRejections: tooLargeRejections,
			VisionRejections:        visionRejections,
			TTFTRejections:          ttftRejections,
			BestTTFTMs:              bestTTFTMs,
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
	// Re-check the vision and trait gates under the provider lock too: the
	// winner must still advertise a vision-capable build if the request carries
	// media, and must still pass the trait gates — a render-broken build is
	// fenced for every shape, the tools version floor for tool requests — and
	// must not have entered the shape-keyed inference-error cooldown (all folded
	// into providerCanAdmitLocked) between snapshot and reservation.
	if !r.providerCanAdmitLocked(p, model, pr.Traits, relaxTrust) ||
		(pr.RequiresVision && !r.providerServesVisionModelLocked(p, model)) {
		return nil, RoutingDecision{
			Model:                   model,
			CandidateCount:          candidateCount,
			CapacityRejections:      capacityRejections,
			ModelTooLargeRejections: tooLargeRejections,
			VisionRejections:        visionRejections,
			TTFTRejections:          ttftRejections,
			BestTTFTMs:              bestTTFTMs,
		}
	}

	pr.ProviderID = p.ID
	p.addPendingLocked(pr)
	if p.Status != StatusUntrusted && p.Status != StatusOffline {
		p.Status = StatusServing
	}
	if !slotStateModelLoaded(selected.snapshot.slotState) {
		r.RecordWarmPoolColdDispatch(model)
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
		VisionRejections:        visionRejections,
		TTFTRejections:          ttftRejections,
		BestTTFTMs:              bestTTFTMs,
		TTFTMs:                  bd.TTFTMs,
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
// Returns (winner, candidateCount, capacityRejections, modelTooLargeRejections,
// visionRejections, ttftRejections, bestTTFTMs).
func (r *Registry) selectBestCandidateLockedFull(model string, pr *PendingRequest, excludeIDs ...string) (*routingCandidate, int, int, int, int, int, float64) {
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
	visionRejections := 0
	ttftRejections := 0
	bestTTFTMs := 0.0
	enforceTTFT := pr.MaxTTFTMs > 0
	affinityProviderID := ""
	affinityLookup := pr.CacheAffinityKey != "" && pr.ConsumerKey != ""
	if affinityLookup && r.cacheAffinityBonusMs > 0 {
		affinityProviderID = r.cacheAffinity.lookup(pr.ConsumerKey, model, pr.CacheAffinityKey, time.Now())
	}
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
		// snapshotProviderLocked applies every per-provider gate via the shared
		// providerPassesRoutingGatesLocked, INCLUDING the shape-keyed
		// inference-error cooldown and the trait gates (render-broken fences all
		// shapes; the tools version floor fences tool requests). A failing
		// provider is simply dropped here.
		snap, ok := r.snapshotProviderLocked(p, model, pr.Traits, relaxTrust)
		if !ok {
			continue
		}
		// Vision gate: a media request must only go to a provider advertising a
		// vision-capable build of this model. Providers reach here only if they
		// already serve the model (snapshot ok), so a miss here means "serves it,
		// but text-only" — counted separately so the caller can return a precise
		// "no vision-capable provider" error rather than a busy/429. snapshot
		// released p.mu, so re-take it for the p.Models read.
		if pr.RequiresVision {
			p.mu.Lock()
			servesVision := r.providerServesVisionModelLocked(p, model)
			p.mu.Unlock()
			if !servesVision {
				visionRejections++
				continue
			}
		}
		candidate, reason, ok := r.buildCandidateWithReason(snap, pr)
		if !ok {
			switch reason {
			case rejectCapacity:
				capacityRejections++
			case rejectModelTooLarge:
				tooLargeRejections++
			case rejectVisionUnsupported:
				visionRejections++
			}
			continue
		}

		// Track the best reliable TTFT seen among providers that passed all
		// structural and capacity gates. Even if this candidate is over the
		// ceiling, the value is used for Retry-After on the TTFT 429 path.
		// Providers without BackendCapacity do not contribute a reliable TTFT
		// estimate, so they are skipped here.
		if snap.hasBackendCapacity && (candidate.breakdown.TTFTMs < bestTTFTMs || bestTTFTMs == 0) {
			bestTTFTMs = candidate.breakdown.TTFTMs
		}

		// Enforce the per-request TTFT ceiling for public inference routes.
		// Providers above the threshold are counted as TTFT rejections and
		// excluded from cost-based selection so the router cannot pick a
		// provider that misses the OpenRouter SLA target. Providers without
		// BackendCapacity have no reliable TTFT estimate, so the ceiling is
		// not enforced on them (matching the preflight behavior).
		if enforceTTFT && snap.hasBackendCapacity && candidate.breakdown.TTFTMs > pr.MaxTTFTMs {
			ttftRejections++
			continue
		}

		if affinityProviderID != "" && p.ID == affinityProviderID {
			bonus := r.cacheAffinityBonusMs
			if bonus > candidate.costMs {
				bonus = candidate.costMs
			}
			candidate.costMs -= bonus
			candidate.breakdown.Total = candidate.costMs
		}
		candidates = append(candidates, candidate)
		candidateCount++
	}

	if len(candidates) == 0 {
		return nil, candidateCount, capacityRejections, tooLargeRejections, visionRejections, ttftRejections, bestTTFTMs
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

	// Version-diverse retry (SOFT): when a previous attempt failed on a given
	// binary version, prefer candidates running any OTHER version so a
	// deterministic per-version bug (e.g. a chat-template render crash) cannot
	// consume every retry on identical binaries. Diversity never fails closed:
	// when every candidate runs the avoided version, keep the full pool rather
	// than failing the request.
	if pr.Traits.AvoidVersion != "" {
		diverse := make([]*routingCandidate, 0, len(pool))
		for _, c := range pool {
			if providerVersion(c.provider) != pr.Traits.AvoidVersion {
				diverse = append(diverse, c)
			}
		}
		if len(diverse) > 0 {
			pool = diverse
		}
	}

	// Decode-floor quality preference (SOFT, Routing v2 W2): when a per-request
	// decode floor is set, prefer candidates that would still deliver
	// >= MinDecodeTPS to a newly admitted request, so the router does not overpack
	// a provider into a degraded (low tok/s) stream. Never fails closed — if no
	// candidate clears the floor, keep the full pool so the request is still
	// served (growing warm capacity / queueing to protect quality is handled
	// upstream, not by dropping the request here).
	if pr.MinDecodeTPS > 0 {
		quality := make([]*routingCandidate, 0, len(pool))
		for _, c := range pool {
			if projectedPerRequestDecodeTPS(c.snapshot) >= pr.MinDecodeTPS {
				quality = append(quality, c)
			}
		}
		if len(quality) > 0 {
			pool = quality
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
	if affinityProviderID != "" {
		for _, c := range nearTies {
			if c.provider.ID == affinityProviderID {
				winner = c
				break
			}
		}
	}
	r.logRoutingDecision(model, pr, winner, candidateCount)
	return winner, candidateCount, capacityRejections, tooLargeRejections, visionRejections, ttftRejections, bestTTFTMs
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

// providerVersion reads the provider's binary version under p.mu (set by the
// API layer after registration; p.mu guards provider field access — mirrors
// providerOwnedBy). Used by the version-diverse retry pool filter.
func providerVersion(p *Provider) string {
	if p == nil {
		return ""
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.Version
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
			r.providerSupportsPrivateTextLocked(p) &&
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

// providerPassesRoutingGatesLocked is the single source of truth for the
// per-provider structural/privacy/cooldown/trait gates a request must clear
// before a provider is eligible to serve it. snapshotProviderLocked (the
// production dispatch hot path) and QuickCapacityCheck (the preflight) BOTH call
// it so the two can never drift — a prior bug had QuickCapacityCheck silently
// missing the dispatch-load cooldown, the inference-error cooldown, and the
// trait gates, so the preflight reported capacity that routing then refused.
//
// Gates, in evaluation order:
//   - catalog membership (advertises an allowed build of the model)
//   - dispatch-load cooldown (pair instant-503'd on "insufficient memory")
//   - inference-error cooldown, SHAPE-KEYED to traits.CooldownShape() (pair
//     returning repeated provider-side 5xx for THIS request shape)
//   - status not offline/untrusted
//   - private-only admission (only the owner's self-route may use it)
//   - hardware-trust floor (relaxed to TrustNone for the owner's own machine)
//   - runtime verified
//   - private-text support (E2E privacy backstop)
//   - challenge freshness
//   - trait eligibility: render-broken fences EVERY request shape; version
//     floors are trait-scoped (tools-only today)
//
// selfRouteOwner relaxes only the trust floor and private-only admission for a
// caller's own (possibly un-enrolled) machine; every privacy-critical gate
// still applies. Caller holds r.mu and p.mu.
func (r *Registry) providerPassesRoutingGatesLocked(p *Provider, model string, traits RequestTraits, selfRouteOwner bool, now time.Time) bool {
	if !r.providerServesCatalogModelLocked(p, model) {
		return false
	}
	// Skip a provider-model pair cooling down after a dispatch-time load
	// failure ("insufficient memory") — it would instant-503 again, burning a
	// dispatch attempt.
	if r.dispatchLoadCooldownActiveLocked(p.ID, model, now) {
		return false
	}
	// Skip a triple quarantined by the inference-error circuit breaker for THIS
	// request shape: repeated provider-side (5xx) failures — e.g. a deterministic
	// chat-template render crash on tool schemas — mean a retry here fails
	// identically, so routing must fall to a different provider. Shape-keyed so a
	// tool failure does not deroute clean text traffic. Cleared by
	// RecordInferenceSuccess (same shape) or by TTL expiry.
	if r.inferenceErrorCooldownActiveLocked(p.ID, model, traits.CooldownShape(), now) {
		return false
	}
	if p.Status == StatusOffline || p.Status == StatusUntrusted {
		return false
	}
	// A private-only machine never serves the public fleet — only its owner's
	// self-route requests.
	if p.PrivateOnly && !selfRouteOwner {
		return false
	}
	minTrust := r.MinTrustLevel
	if selfRouteOwner {
		minTrust = TrustNone
	}
	if trustRank(p.TrustLevel) < trustRank(minTrust) {
		return false
	}
	if !p.RuntimeVerified {
		return false
	}
	if !r.providerSupportsPrivateTextLocked(p) {
		return false
	}
	if p.LastChallengeVerified.IsZero() || now.Sub(p.LastChallengeVerified) > challengeFreshnessMaxAge {
		return false
	}
	// Trait eligibility: a render-broken build is fenced for EVERY request shape
	// (a crashing chat template breaks plain text, tools, and multimodal alike),
	// while the capability version floors stay trait-scoped (tools-only today).
	if !r.providerEligibleForTraitsLocked(p, model, traits) {
		return false
	}
	return true
}

// snapshotProviderLocked builds a routing snapshot for p, returning ok=false
// when p fails any structural/privacy/capacity/trait gate. selfRouteOwner is
// true when this is a self-route request and p is owned by the requesting
// account. It (1) drops the hardware-trust floor to TrustNone — a personal Mac
// will not be MDM/MDA enrolled, so without this it would be unroutable to its
// own owner — and (2) admits a private-only machine, which is otherwise
// excluded from the public fleet. Every privacy-critical gate (RuntimeVerified,
// private-text support, challenge freshness) still applies, so plaintext is
// never exposed and only the genuinely-signed provider binary serves. traits
// carry the request shape into the shape-keyed inference-error cooldown and the
// render-broken / version-floor eligibility gates.
func (r *Registry) snapshotProviderLocked(p *Provider, model string, traits RequestTraits, selfRouteOwner bool) (routingSnapshot, bool) {
	now := time.Now()

	p.mu.Lock()
	defer p.mu.Unlock()

	if !r.providerPassesRoutingGatesLocked(p, model, traits, selfRouteOwner, now) {
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
	snap.hasBackendCapacity = p.BackendCapacity != nil

	if p.BackendCapacity != nil {
		snap.gpuMemoryActiveGB = p.BackendCapacity.GPUMemoryActiveGB
		snap.freeForLoadGB = p.BackendCapacity.FreeForLoadGB
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
			snap.observedPrefillTPS = slot.ObservedPrefillTPS
			snap.activeTokenBudgetUsed = slot.ActiveTokenBudgetUsed
			snap.activeTokenBudgetMax = slot.ActiveTokenBudgetMax
			snap.queuedTokenBudget = slot.QueuedTokenBudget
			break
		}
	}
	snap.modelLoaded = slotStateModelLoaded(snap.slotState)
	snap.availableOnDisk = !snap.modelLoaded
	snap.fleetMedianTPS = r.tpsRegistry.Median(model, p.Hardware.ChipFamily)

	return snap, true
}

// coldLoadCatalogGBToMemGiB converts a model's catalog on-disk size (decimal GB,
// TotalSizeBytes/1e9, unpadded) into the provider's load-gate basis (padded GiB).
// The provider's ModelLoadAdmission.canLoad weighs estimatedMemoryGb = on-disk
// bytes × 1.2 (scanner memory-overhead) / 2^30, and free_for_load_gb is reported
// in that same padded-GiB basis. So a raw catalog size must be padded+converted
// the same way before comparing, or a near-threshold model whose RAW size fits
// but whose PADDED estimate doesn't would be admitted here and then 503'd at load
// (Codex #390). 1.2 mirrors the provider scanner's overhead factor; (1e9/2^30)
// converts decimal GB → GiB. Conservative: if the scanner's factor ever drops,
// this stays safe (slightly stricter); it must not be set BELOW the provider's.
const coldLoadCatalogGBToMemGiB = 1.2 * (1e9 / float64(int64(1)<<30)) // ≈ 1.1176

// backendFreeForLoadGB returns the provider-reported free_for_load_gb (nil-safe).
// Caller must hold the provider lock when passing p.BackendCapacity.
func backendFreeForLoadGB(bc *protocol.BackendCapacity) *float64 {
	if bc == nil {
		return nil
	}
	return bc.FreeForLoadGB
}

// reportedFreeForLoadAdmits reports whether a cold load of a model with the given
// catalog size (decimal GB) fits the provider's reported free_for_load_gb (max
// loadable model weight, padded GiB — the provider's authoritative gate). The
// second return is whether the provider reported the value at all; false means
// the caller should fall back to its static hardware heuristic (legacy provider,
// or unknown catalog size that can't be normalized). Used by every cold-load
// decision path (direct admission, the swap planner, the warm pool, and the
// cold-spill predicate) so they cannot drift.
func reportedFreeForLoadAdmits(catalogSizeGB float64, freeForLoadGB *float64) (admit bool, reported bool) {
	if freeForLoadGB == nil || catalogSizeGB <= 0 {
		return false, false
	}
	return catalogSizeGB*coldLoadCatalogGBToMemGiB <= *freeForLoadGB, true
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
	// provider will evict idle models to make room (LRU eviction), so we check
	// whether the model can be loaded rather than requiring it to fit alongside
	// existing loaded models. The provider handles the swap autonomously.
	//
	// However, if the provider has in-flight requests (totalPending > 0), it
	// cannot evict the currently-serving model. In that case, fall through to the
	// standard free-memory check which requires room alongside active models.
	if snap.availableOnDisk && !snap.modelLoaded && snap.totalPending == 0 {
		// Preferred: the provider reports freeForLoadGB — the max model WEIGHT it
		// can load right now, already net of the 90% unified cap, OS/operator
		// reserve, activation+min-KV headroom, real OS-available memory, and
		// eviction of idle models. The single source of truth, normalized to the
		// provider's padded-GiB load basis so it exactly mirrors the provider's own
		// ModelLoadAdmission gate (no over-admit → OOM, no under-admit on evictable
		// weights).
		if admit, reported := reportedFreeForLoadAdmits(snap.modelSizeGB, snap.freeForLoadGB); reported {
			return admit
		}
		// Fallback for legacy providers that don't report freeForLoadGB: the old
		// total-memory heuristic (provider evicts idle models, so compare against
		// total rather than free). Coarser — can't see the unified cap or OS
		// baseline — but only used until the fleet reports the field.
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

// PrefillToDecodeRatio returns the current decode→prefill fallback multiplier
// (the value used by resolvedPrefillTPS when a provider does not report a
// measured prefill rate). Exposed for the routing simulation harness.
func PrefillToDecodeRatio() float64 {
	return prefillToDecodeRatio
}

func resolvedPrefillTPS(p *Provider) float64 {
	if p.PrefillTPS > 0 {
		return p.PrefillTPS
	}
	return resolvedDecodeTPS(p) * prefillToDecodeRatio
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

// providerCanAdmitLocked is the under-the-provider-lock admit re-check run in
// ReserveProviderEx after a winner is selected: it re-applies every routing
// gate (via the shared providerPassesRoutingGatesLocked — same catalog, trust,
// privacy, challenge, shape-keyed inference-error cooldown, and trait gates as
// selection) plus the admit-specific capacity gates (concurrency headroom and
// non-crashed/non-reloading slot state). This guards the race where the
// provider's state changed between snapshot and reservation. Caller holds r.mu
// and p.mu.
func (r *Registry) providerCanAdmitLocked(p *Provider, model string, traits RequestTraits, selfRouteOwner bool) bool {
	now := time.Now()
	if !r.providerPassesRoutingGatesLocked(p, model, traits, selfRouteOwner, now) {
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
// right now. It runs the SAME per-provider gates as the full routing path —
// via the shared providerPassesRoutingGatesLocked (status, trust, runtime,
// privacy, challenge freshness, dispatch-load + shape-keyed inference-error
// cooldowns, and the trait gates: render-broken fences every shape, the tools
// version floor fences tool requests) — plus the capacity gates (concurrency
// headroom, slot state, free memory) but does NOT reserve capacity or create
// pending requests. traits carry the request shape so the preflight excludes a
// provider for exactly the reasons routing would, instead of reporting phantom
// capacity that routing then refuses (the drift this consolidation closes).
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
func (r *Registry) QuickCapacityCheck(model string, estimatedPromptTokens, requestedMaxTokens int, traits RequestTraits, allowedSerials ...string) (candidateCount, capacityRejections, modelTooLarge int) {
	candidateCount, capacityRejections, modelTooLarge, _, _ = r.quickCapacityCheck(model, estimatedPromptTokens, requestedMaxTokens, traits, false, allowedSerials...)
	return candidateCount, capacityRejections, modelTooLarge
}

func (r *Registry) QuickCapacityCheckForRequest(model string, estimatedPromptTokens, requestedMaxTokens int, traits RequestTraits, requiresVision bool, allowedSerials ...string) (candidateCount, capacityRejections, modelTooLarge int) {
	candidateCount, capacityRejections, modelTooLarge, _, _ = r.quickCapacityCheck(model, estimatedPromptTokens, requestedMaxTokens, traits, requiresVision, allowedSerials...)
	return candidateCount, capacityRejections, modelTooLarge
}

func (r *Registry) QuickCapacityCheckWithTTFTForRequest(model string, estimatedPromptTokens, requestedMaxTokens int, traits RequestTraits, requiresVision bool, allowedSerials ...string) (candidateCount, capacityRejections, modelTooLarge int, bestTTFT time.Duration, hasTTFT bool) {
	return r.quickCapacityCheck(model, estimatedPromptTokens, requestedMaxTokens, traits, requiresVision, allowedSerials...)
}

func (r *Registry) quickCapacityCheck(model string, estimatedPromptTokens, requestedMaxTokens int, traits RequestTraits, requiresVision bool, allowedSerials ...string) (candidateCount, capacityRejections, modelTooLarge int, bestTTFT time.Duration, hasTTFT bool) {
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

	unknownTTFTCandidate := false
	now := time.Now()
	for _, p := range r.providers {
		// Filter by allowed serials before acquiring the provider lock
		// (providerMatchesAllowedSerial takes p.mu internally).
		if len(allowedSet) > 0 && !providerMatchesAllowedSerial(p, allowedSet) {
			continue
		}

		p.mu.Lock()

		// Per-provider routing gates (same source of truth as snapshotProviderLocked
		// and the admit re-check). This pre-flight only runs for public
		// (non-self-route) requests, so selfRouteOwner is false — private-only
		// machines are excluded unconditionally.
		if !r.providerPassesRoutingGatesLocked(p, model, traits, false, now) {
			p.mu.Unlock()
			continue
		}
		if p.SystemMetrics.ThermalState == "critical" {
			p.mu.Unlock()
			continue
		}
		if requiresVision && !r.providerServesVisionModelLocked(p, model) {
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
			provider:           p,
			model:              model,
			slotState:          "unknown",
			totalPending:       p.pendingCount(),
			systemMetrics:      p.SystemMetrics,
			decodeTPS:          resolvedDecodeTPS(p),
			prefillTPS:         resolvedPrefillTPS(p),
			totalMemoryGB:      float64(p.Hardware.MemoryGB),
			modelSizeGB:        r.catalogSizeGBLocked(model),
			minRAMGb:           r.catalogMinRAMGbLocked(model),
			hasBackendCapacity: p.BackendCapacity != nil,
		}
		for _, pending := range p.pendingReqs {
			if pending.Model != model {
				continue
			}
			snap.pendingForModel++
			snap.pendingMaxTokens += pendingTokenBudget(pending)
		}
		if snap.hasBackendCapacity {
			snap.gpuMemoryActiveGB = p.BackendCapacity.GPUMemoryActiveGB
			snap.freeForLoadGB = p.BackendCapacity.FreeForLoadGB
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
				snap.observedDecodeTPS = slot.ObservedDecodeTPS
				snap.observedPrefillTPS = slot.ObservedPrefillTPS
				snap.activeTokenBudgetUsed = slot.ActiveTokenBudgetUsed
				snap.activeTokenBudgetMax = slot.ActiveTokenBudgetMax
				snap.queuedTokenBudget = slot.QueuedTokenBudget
				snap.maxTokensPotential = slot.MaxTokensPotential
				break
			}
		}
		snap.modelLoaded = slotStateModelLoaded(snap.slotState)
		snap.availableOnDisk = !snap.modelLoaded
		snap.fleetMedianTPS = r.tpsRegistry.Median(model, p.Hardware.ChipFamily)

		p.mu.Unlock()

		// Absolute hardware-fit gate (mirrors buildCandidateWithReason). A model
		// that can never fit this node is a permanent miss, not transient
		// capacity pressure — count it separately so the caller never 429s it.
		// Skipped for a resident ("running"/"idle") model, which has demonstrably
		// fit.
		if !slotStateModelLoaded(snap.slotState) && !modelFitsHardware(snap.minRAMGb, snap.modelSizeGB, snap.totalMemoryGB) {
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
		if snap.hasBackendCapacity {
			ttft := estimatedTTFTFromSnapshot(snap, estimatedPromptTokens)
			if !hasTTFT || ttft < bestTTFT {
				bestTTFT = ttft
				hasTTFT = true
			}
		} else {
			unknownTTFTCandidate = true
		}
	}
	if unknownTTFTCandidate {
		return candidateCount, capacityRejections, modelTooLarge, 0, false
	}
	return candidateCount, capacityRejections, modelTooLarge, bestTTFT, hasTTFT
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
