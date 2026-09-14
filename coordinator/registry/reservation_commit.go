package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/routingcost"
)

// commitProviderReservation is the short commit phase. It repeats the full
// current-state capacity chain before adding the pending debit, so concurrent
// scans cannot double-spend a provider's shared cross-model token pool.
//
// Locking (reserveCommitShared, the default): r.mu is held for READING — the
// commit needs the provider identity, catalog and cache-routing configuration
// to be stable, not the fleet to be frozen — and everything that decides the
// reservation runs under the winner's p.mu in ONE section: the fresh snapshot,
// the cost rebuild, the "winner unchanged since scan" compare, the admit
// re-check, the probe claim and the pending debit. Double-booking is prevented
// where it always was (providerCanAdmitLockedEx + addPendingLocked under
// p.mu); the herd compare is exact because it compares the winner's own
// counters read under the same p.mu that debits them; the half-open probe
// claim is check-and-claim under gate.mu. Nothing here drains the fleet-scan
// reader batch, which is what each write acquisition cost before.
// reserveCommitGlobal takes r.mu for writing instead — the previous
// fleet-wide serialization, kept as the kill switch.
func (r *Registry) commitProviderReservation(
	model string,
	pr *PendingRequest,
	scan providerReservationScan,
	excludeIDs ...string,
) (*Provider, *routingCandidate, reservationCommitOutcome, RoutingDecision) {
	lock := r.commitLock("commit")
	lock.lock()
	defer lock.unlock()

	// The shared scan and any lock wait consume the same absolute request
	// clock as queueing and provider handoff. Never debit capacity for work whose
	// first-content budget is already gone. One clock read serves the whole
	// commit section (deadline, re-snapshot, cost, admit, probe claim).
	now := time.Now()
	if !pr.RefreshFirstContentBudget(now) {
		return nil, nil, reservationDeadlineExpired, RoutingDecision{}
	}

	// Cache routing reconfiguration after the shared scan invalidates its cost
	// ordering. Retry from a new scan rather than committing a stale discount.
	if r.cacheRouting != scan.cacheTracker || r.cacheRoutingMode != scan.cacheMode {
		return nil, nil, reservationNeedsRescan, RoutingDecision{}
	}
	selected := scan.selected
	if selected == nil || selected.provider == nil {
		return nil, nil, reservationCandidateRejected, RoutingDecision{}
	}
	p := selected.provider
	if current, ok := r.providers[p.ID]; !ok || current != p {
		return nil, nil, reservationCandidateRejected, RoutingDecision{}
	}

	// A breaker bypass is valid only while breaker-open providers remain the
	// sole route. Re-run the normal pass at commit time; this rare emergency path
	// re-scans under the commit lock so a newly healthy provider is preferred
	// over the fail-open choice.
	if scan.candidates.ignoreProviderBreaker {
		normalWinner, normal := r.selectBestCandidateScanLocked(
			model, pr, false, excludeIDs...)
		if normalWinner != nil || !shouldBypassBreakerFailOpen(
			normalWinner, normal.breakerRejected,
			normal.capacityRejections, normal.ttftRejections) {
			return nil, nil, reservationNeedsRescan, RoutingDecision{}
		}
	}

	// Ownership / serial filters take p.mu themselves — evaluate them before
	// the commit section below acquires it.
	owned := providerOwnedBy(p, pr.OwnerAccountID)
	if pr.SelfRouteOnly && !owned {
		return nil, nil, reservationCandidateRejected, RoutingDecision{}
	}
	if len(pr.AllowedProviderSerials) > 0 {
		allowed := make(map[string]struct{}, len(pr.AllowedProviderSerials))
		for _, serial := range pr.AllowedProviderSerials {
			allowed[serial] = struct{}{}
		}
		if !providerMatchesAllowedSerial(p, allowed) {
			return nil, nil, reservationCandidateRejected, RoutingDecision{}
		}
	}
	relaxTrust := owned && (pr.SelfRouteOnly || pr.PreferOwner)

	// Commit section: snapshot, cost, compare, admit and debit under ONE p.mu
	// hold, so no other commit can change this provider between the compare
	// and the debit.
	p.mu.Lock()
	defer p.mu.Unlock()
	var snapshot routingSnapshot
	if ok, _ := r.snapshotProviderIntoPLockedEx(
		&snapshot, p, model, pr.Traits, relaxTrust, scan.candidates.ignoreProviderBreaker, now); !ok {
		return nil, nil, reservationCandidateRejected, RoutingDecision{}
	}
	if pr.RequiresVision && !r.providerServesVisionModelLocked(p, model, relaxTrust) {
		return nil, nil, reservationCandidateRejected,
			routingDecisionForCommitRejection(model, rejectVisionUnsupported, false)
	}
	candidate, reason, ok := r.buildCandidateWithReason(snapshot, pr, now)
	if !ok {
		return nil, nil, reservationCandidateRejected,
			routingDecisionForCommitRejection(model, reason, false)
	}
	if pr.MaxTTFTMs > 0 && !pr.RequiresVision && snapshot.HasBackendCapacity &&
		candidate.breakdown.TTFTMs > pr.MaxTTFTMs {
		return nil, nil, reservationCandidateRejected,
			routingDecisionForCommitRejection(model, rejectNone, true)
	}
	r.applyCacheRoutingCostPLocked(p, model, pr, candidate)

	// Another reservation or cache quarantine changed this winner after the
	// shared scan. Re-scan before committing stale cost or affinity preference.
	// Quarantine can change affinity without changing any cost. The counters here
	// were read under the p.mu this section still holds, so a concurrent commit
	// on the same provider is either fully before (and visible) or fully after.
	if snapshot.PendingForModel != selected.snapshot.PendingForModel ||
		snapshot.TotalPending != selected.snapshot.TotalPending ||
		candidate.effectiveQueue != selected.effectiveQueue ||
		candidate.costMs != selected.costMs ||
		candidate.cacheAffinityEligible != selected.cacheAffinityEligible {
		return nil, nil, reservationNeedsRescan, RoutingDecision{}
	}

	if !r.providerCanAdmitLockedEx(
		p, model, pr.Traits, relaxTrust, scan.candidates.ignoreProviderBreaker, now) ||
		(pr.RequiresVision && !r.providerServesVisionModelLocked(p, model, relaxTrust)) {
		return nil, nil, reservationCandidateRejected, RoutingDecision{}
	}
	// Half-open capacity probe: check-and-claim under gate.mu (p.mu → gate.mu).
	// A pair whose expired cooldown was claimed by a concurrent commit for the
	// same identity is closed again; reject rather than leak a second probe.
	if !r.tryClaimCapacityProbe(p, model, now) {
		return nil, nil, reservationCandidateRejected,
			routingDecisionForCommitRejection(model, rejectCapacity, false)
	}

	pr.ProviderID = p.ID
	p.addPendingLocked(pr)
	if p.Status != StatusUntrusted && p.Status != StatusOffline {
		p.Status = StatusServing
	}
	if !routingcost.SlotStateModelLoaded(candidate.snapshot.SlotState) {
		r.RecordWarmPoolColdDispatch(model)
	}
	if !pr.RequiresVision && candidate.breakdown.RawTTFTMs > 0 && candidate.breakdown.StateMs == 0 {
		routingPolicy.NotePrediction(
			pr.RequestID, pr.Attempt, model, candidate.snapshot.ChipFamily,
			candidate.breakdown.RawTTFTMs)
	}
	if candidate.breakdown.CacheDiscountMs > 0 {
		pr.CacheSelectionMode = "active"
		pr.CacheSelectionTier = candidate.cacheTier
		pr.CacheSelectionDiscountMs = candidate.breakdown.CacheDiscountMs
		pr.CacheSelectionEstimatedTTFTSavedMs = candidate.cacheEstimatedTTFTSavedMs
		pr.CacheSelectionSelected = true
	}
	return p, candidate, reservationCommitted, RoutingDecision{}
}

// providerCanAdmitLockedEx is providerCanAdmitLocked with an explicit
// ignoreProviderBreaker switch. ReserveProviderEx sets it true ONLY when the
// selected winner is itself node-health-breaker-open — which can happen only
// because the selectBestCandidateLockedFull fail-open fallback pass chose it.
// Without this, the admit re-check would re-apply the breaker and reject the
// very candidate the fail-open valve just selected, derouting the fleet anyway.
// The default wrapper (breaker honored) is unchanged for every other caller.
// Caller holds r.mu and p.mu.
func (r *Registry) providerCanAdmitLockedEx(p *Provider, model string, traits RequestTraits, selfRouteOwner bool, ignoreProviderBreaker bool, now time.Time) bool {
	if !r.providerPassesRoutingGatesLockedEx(p, model, traits, selfRouteOwner, now, ignoreProviderBreaker, false) {
		return false
	}
	// Apply the SAME quality-concurrency cap as the selection snapshot and the
	// preflight. This is the final admit re-check in ReserveProviderEx; if a
	// heartbeat bumped NumRunning after the snapshot was built, the legacy flat-cap
	// check here would let a box that just reached its quality cap be over-admitted.
	if !r.hasConcurrencyHeadroomForModelCapResolvedLocked(p, model) {
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
