package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/candidatearena"
)

// ScanCandidates evaluates one eligibility pass without selecting or reserving
// a provider. Callers may retain the result; a later commit always revalidates
// live state under the provider lock.
func (p *ReservationPlanner) ScanCandidates(model string, pending *PendingRequest, ignoreProviderBreaker bool, excludeIDs ...string) CandidateScan {
	p.registry.mu.RLock()
	defer p.registry.mu.RUnlock()
	return p.scanCandidatesLocked(model, pending, ignoreProviderBreaker, excludeIDs...)
}

// scanCandidatesLocked builds the eligible candidate pool through every gate,
// then narrows it by the request's soft preferences. The caller holds r.mu and
// no provider lock. Candidate storage belongs to this scan, never to a provider.
func (planner *ReservationPlanner) scanCandidatesLocked(model string, pr *PendingRequest, ignoreProviderBreaker bool, excludeIDs ...string) CandidateScan {
	return planner.scanCandidatesLockedStorage(nil, model, pr, ignoreProviderBreaker, excludeIDs...)
}

func (planner *ReservationPlanner) scanCandidatesLockedStorage(storage *reservationCandidateStorage, model string, pr *PendingRequest, ignoreProviderBreaker bool, excludeIDs ...string) CandidateScan {
	r := planner.registry
	// Nil maps read as empty; only allocate when there is something to hold.
	var excludeSet map[string]struct{}
	if len(excludeIDs)+len(pr.ExcludedProviderIDs) > 0 {
		excludeSet = make(map[string]struct{}, len(excludeIDs)+len(pr.ExcludedProviderIDs))
		for _, id := range excludeIDs {
			excludeSet[id] = struct{}{}
		}
		for _, id := range pr.ExcludedProviderIDs {
			excludeSet[id] = struct{}{}
		}
	}
	var allowedSerials map[string]struct{}
	if len(pr.AllowedProviderSerials) > 0 {
		allowedSerials = make(map[string]struct{}, len(pr.AllowedProviderSerials))
		for _, serial := range pr.AllowedProviderSerials {
			allowedSerials[serial] = struct{}{}
		}
	}

	// Collect the entire eligible pool before selecting: one-pass near-tie
	// tracking drops earlier candidates when a later candidate becomes best.
	// Copy index members before taking any provider lock.
	providers := r.providersForModelLocked(model)
	candidates := make([]*routingCandidate, 0, len(providers))
	// Retain compact evidence; full evaluation storage stays on the stack.
	arena := candidatearena.Arena[routingCandidate]{Storage: storage.forScan(len(providers))}
	var scan candidateScan
	scan.planOrderFactory = r.planOrderFactory
	now := time.Now()
	var snapshot routingSnapshot
	for _, p := range providers {
		scan.Scanned++
		owned := providerOwnedBy(p, pr.OwnerAccountID)
		if pr.SelfRouteOnly && !owned {
			scan.tallyGate(GateAllowlist)
			continue
		}
		if len(allowedSerials) > 0 {
			if !providerMatchesAllowedSerial(p, allowedSerials) {
				scan.tallyGate(GateAllowlist)
				continue
			}
		}
		if _, excluded := excludeSet[p.ID]; excluded {
			scan.tallyGate(GateExcluded)
			continue
		}
		// Relax trust only for the caller's own machine, never the public pool.
		relaxTrust := owned && (pr.SelfRouteOnly || pr.PreferOwner)
		c := arena.Next()
		ok, gateReason := r.snapshotProviderIntoLockedEx(&snapshot, p, model, pr.Traits, relaxTrust, ignoreProviderBreaker, now)
		if !ok {
			arena.Release(c)
			scan.tallyGate(gateReason)
			breaker, capacity := r.classifyRejectedProvider(
				r.gateViewOf(p), model, pr.Traits, relaxTrust, ignoreProviderBreaker, now)
			if breaker {
				scan.BreakerRejected++
			}
			if capacity {
				scan.CapacityRejections++
			}
			continue
		}
		// The snapshot released p.mu; reacquire it for the model advertisement.
		if pr.RequiresVision {
			p.mu.Lock()
			servesVision := r.providerServesVisionModelLocked(p, model, relaxTrust)
			p.mu.Unlock()
			if !servesVision {
				arena.Release(c)
				scan.VisionRejections++
				scan.tallyGate(GateVision)
				continue
			}
		}
		reason, gateReason, ok := r.buildCandidateInto(c, &snapshot, pr, now)
		if !ok {
			arena.Release(c)
			switch reason {
			case rejectCapacity:
				scan.CapacityRejections++
			case rejectModelTooLarge:
				scan.ModelTooLargeRejections++
			case rejectVisionUnsupported:
				scan.VisionRejections++
			}
			scan.tallyGate(gateReason)
			continue
		}

		r.applyCacheRoutingCost(p, model, pr, c, &snapshot)
		r.estimateFirstContent(c, &snapshot, pr, now)
		bestTTFT := c.firstContent.ConservativeMs
		if bestTTFT > 0 && (scan.BestTTFTMs == 0 || bestTTFT < scan.BestTTFTMs) {
			scan.BestTTFTMs = bestTTFT
		}
		if !firstContentCandidateAllowed(c, pr) {
			arena.Release(c)
			scan.TTFTRejections++
			scan.tallyGate(GateTTFTCeiling)
			continue
		}

		// Best-idle covers every routable candidate, before soft narrowing.
		scan.noteBestIdle(c)
		candidates = append(candidates, c)
		scan.CandidateCount++
	}
	// An indexed scan visits advertisements, not the entire fleet.
	scan.candidateSetSize = scan.Scanned - int(scan.GateRejections[GateNotServingModel])

	// Every preference falls back to the existing pool when no candidate fits.
	pool := candidates
	if pr.PreferOwner {
		pool = preferRoutingCandidates(pool, func(c *routingCandidate) bool {
			return providerOwnedBy(c.provider, pr.OwnerAccountID)
		})
	}
	pool = preferFirstContentCandidates(pool)
	if pr.Traits.AvoidVersion != "" {
		pool = preferRoutingCandidates(pool, func(c *routingCandidate) bool {
			return providerVersion(c.provider) != pr.Traits.AvoidVersion
		})
	}
	if pr.MinDecodeTPS > 0 {
		pool = preferRoutingCandidates(pool, func(c *routingCandidate) bool {
			return c.snapshot.projectedDecodeTPS(c.snapshot.backendRunning) >= pr.MinDecodeTPS
		})
	}

	// Top-4 covers the narrowed pool; selection promotes the winner later.
	for _, c := range pool {
		scan.insertTop(c)
	}
	scan.Candidates = pool
	scan.ignoreProviderBreaker = ignoreProviderBreaker
	return scan
}
