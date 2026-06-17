package registry

import (
	"math"
	"math/rand"
	"time"
)

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
		if snap.hasBackendCapacity && (candidate.breakdown.TTFTMs < bestTTFTMs || bestTTFTMs == 0) {
			bestTTFTMs = candidate.breakdown.TTFTMs
		}
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
