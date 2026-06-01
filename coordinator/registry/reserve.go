package registry

import (
	"math"
	"math/rand"
)

// ReserveProvider selects a hardware-routable provider for the request and
// atomically reserves capacity by registering the request in the provider's
// pending set before returning.
func (r *Registry) ReserveProvider(model string, pr *PendingRequest, excludeIDs ...string) *Provider {
	p, _ := r.ReserveProviderEx(model, pr, excludeIDs...)
	return p
}

// SelectProvider returns the best hardware-routable provider for the model
// using the live cost-based selection, WITHOUT reserving capacity. It is a
// read-only view (used by tests and diagnostics) backed by the same selection
// logic as ReserveProvider; the request path uses ReserveProvider, which
// additionally registers the request in the provider's pending set. Providers
// are filtered by the registry's configured MinTrustLevel.
func (r *Registry) SelectProvider(model string, excludeIDs ...string) *Provider {
	r.mu.Lock()
	defer r.mu.Unlock()
	pr := &PendingRequest{RequestID: "select-readonly", Model: model, RequestedMaxTokens: defaultRequestedMaxTokens}
	selected, _, _ := r.selectBestCandidateLockedFull(model, pr, excludeIDs...)
	if selected == nil {
		return nil
	}
	return selected.provider
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
		EffectiveTPS:       selected.effectiveTPS,
		StaticTPS:          selected.snapshot.decodeTPS,
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
		candidates = append(candidates, candidate)
		candidateCount++
	}

	if len(candidates) == 0 {
		return nil, candidateCount, capacityRejections
	}

	var best *routingCandidate
	for _, c := range candidates {
		if best == nil || c.costMs < best.costMs {
			best = c
		}
	}
	nearTies := make([]*routingCandidate, 0, len(candidates))
	for _, c := range candidates {
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
	return winner, candidateCount, capacityRejections
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
