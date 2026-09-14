package registry

import (
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
	p, decision, _ := r.reserveProvider(model, pr, false, excludeIDs...)
	return p, decision
}

type reservationCommitOutcome uint8

const (
	reservationCommitted reservationCommitOutcome = iota
	reservationNeedsRescan
	reservationCandidateRejected
	reservationDeadlineExpired
)

type providerReservationScan struct {
	selected     *routingCandidate
	candidates   candidateScan
	cacheTracker *cacheRoutingTracker
	cacheMode    string
	// Profiler stamps for the decision: time waiting for the scan RLock and
	// the scan+selection itself, in microseconds.
	lockWaitUS int64
	scanUS     int64
}

// reserveProvider is the single selection+reservation implementation behind
// ReserveProviderEx and ReserveProviderWithPlan (dispatch_plan.go). wantPlan
// additionally retains a bounded DispatchPlan of provisional alternates drawn
// from the SAME scan that picked the winner — the plan is a byproduct of the
// one existing pass, never a second scan — and is nil whenever no provider is
// reserved. Selection and reservation are identical in both modes;
// wantPlan=false skips plan construction entirely so legacy callers pay nothing.
//
// In-flight token-budget ledger: the reservation itself IS the debit. Expensive
// fleet scans share r.mu for reading; the winner is then re-snapshotted and
// committed inside a short section under the winner's p.mu (r.mu is only read
// — see commitProviderReservation; the global mode is the kill switch).
// addPendingLocked records the request before that section ends, so every
// later commit on that provider sees the debit through
// fillSnapshotPendingAndPool and freeMemoryAdmits (including the reconstructed
// whole-box pool) before it can reserve. Concurrent scans therefore do not
// double-spend reported headroom across models. Heartbeat re-sync remains safe:
// coordinatorExtra subtracts admission.CommittedTokenBudget, so the coordinator-side
// charge shrinks as the provider begins reporting the admitted work. Completion
// and cancel credit through RemovePending; disconnect drops the whole pending
// set; the budget clamp remains the stale-optimistic backstop.
//
// The two-phase boundary preserves the canonical r.mu → p.mu order. A changed
// ranking or cache configuration requests a fresh shared scan. A candidate that
// became ineligible is excluded from this request's later scans, so reservation
// keeps progressing through untried providers until the scan truthfully finds
// none. The request-absolute first-content clock bounds the loop.
func (r *Registry) reserveProvider(model string, pr *PendingRequest, wantPlan bool, excludeIDs ...string) (*Provider, RoutingDecision, *DispatchPlan) {
	if pr == nil || pr.RequestID == "" {
		return nil, RoutingDecision{Model: model}, nil
	}
	if pr.Model == "" {
		pr.Model = model
	}
	if pr.RequestedMaxTokens <= 0 {
		pr.RequestedMaxTokens = defaultRequestedMaxTokens
	}

	excluded := append([]string(nil), excludeIDs...)
	carried := RoutingDecision{Model: model}
	var last providerReservationScan
	var admitUS int64
	scans := 0
	failedDecision := func() RoutingDecision {
		decision := routingDecisionForFailedScan(model, last.candidates)
		addRoutingRejections(&decision, carried)
		decision.LockWaitUS, decision.ScanUS, decision.AdmitUS = last.lockWaitUS, last.scanUS, admitUS
		decision.ScanCount = scans
		return decision
	}
	for pr.RefreshFirstContentBudget(time.Now()) {
		last = r.scanProviderReservation(model, pr, excluded...)
		scans++
		if last.selected == nil {
			return nil, failedDecision(), nil
		}

		// AdmitUS covers the commit phase: the lock waits plus the
		// current-state re-check and the pending debit.
		tCommitStart := time.Now()
		provider, candidate, outcome, rejected := r.commitProviderReservation(
			model, pr, last, excluded...)
		admitUS = time.Since(tCommitStart).Microseconds()
		switch outcome {
		case reservationNeedsRescan:
			continue
		case reservationCandidateRejected:
			addRoutingRejections(&carried, rejected)
			excluded = append(excluded, last.selected.provider.ID)
			continue
		case reservationDeadlineExpired:
			return nil, failedDecision(), nil
		case reservationCommitted:
			decision := routingDecisionForCandidate(
				model, provider, candidate, last.candidates)
			addRoutingRejections(&decision, carried)
			decision.LockWaitUS, decision.ScanUS, decision.AdmitUS = last.lockWaitUS, last.scanUS, admitUS
			decision.ScanCount = scans
			r.currentTTFTShadow(
				model, pr, candidate, excluded...).applyTo(&decision)
			var plan *DispatchPlan
			if wantPlan {
				// The scan pool is immutable value snapshots plus provider
				// identities. Plan consumption revalidates both before use.
				plan = newDispatchPlan(model, last.candidates, last.selected)
			}
			return provider, decision, plan
		}
	}

	return nil, failedDecision(), nil
}

// scanProviderReservation performs the expensive fleet walk under a shared
// registry lock. Concurrent requests may scan together; no provider capacity is
// consumed until commitProviderReservation takes the winner's p.mu and
// revalidates it against current cross-model pending debits.
func (r *Registry) scanProviderReservation(model string, pr *PendingRequest, excludeIDs ...string) providerReservationScan {
	// Profiler stamps: scan-lock wait (from here to the scan RLock) and the
	// scan itself land on the decision as LockWaitUS / ScanUS; ~25 ns each.
	tScanStart := time.Now()
	// Snapshot receipt-confirmed cache hints before taking the registry scan lock.
	// Query holders outside the scan lock; the later candidate quarantine check
	// uses the same registry -> provider -> tracker order as receipt rejection.
	r.mu.RLock()
	cacheTracker, cacheMode := r.cacheRouting, r.cacheRoutingMode
	// Skip digest derivation and holder lookup unless the request can use them.
	// Only matching holders need a capability snapshot; cold providers are
	// visited once, by the ordinary eligibility scan below.
	wantHints := cacheTracker != nil && cacheMode == CacheRoutingOn &&
		pr.CachePlan.present() && len(r.cacheRouteKeys.route) > 0
	var cacheRouteKey []byte
	if wantHints {
		cacheRouteKey = append([]byte(nil), r.cacheRouteKeys.route...)
	}
	r.mu.RUnlock()
	pr.cacheRoutingHints = nil
	pr.CacheOpportunity = CacheOpportunity{}
	if wantHints {
		pr.cacheRoutingHints, pr.CacheOpportunity = r.cacheRoutingHintsWithObservation(
			model, pr.CachePlan, cacheTracker, cacheRouteKey, cacheMode, time.Now())
	}
	pr.CacheSelectionMode = ""
	pr.CacheSelectionTier = ""
	pr.CacheSelectionDiscountMs = 0
	pr.CacheSelectionEstimatedTTFTSavedMs = 0
	pr.CacheSelectionSelected = false
	if pr.CachePlan.present() && cacheMode == CacheRoutingOn {
		pr.CacheSelectionMode = "active"
	}

	r.mu.RLock()
	tLocked := time.Now()
	// Configuration can change while tracker hints are computed outside r.mu.
	// Revalidate under the scan lock so an off/reconfigure transition is
	// linearizable and stale hints never affect selection.
	if cacheMode == CacheRoutingOff || r.cacheRoutingMode != cacheMode ||
		r.cacheRouting != cacheTracker {
		pr.cacheRoutingHints = nil
		pr.CacheSelectionMode = ""
		pr.CacheOpportunity = CacheOpportunity{}
	}
	selected, candidates := r.selectBestCandidateLockedFull(model, pr, excludeIDs...)
	if r.reservationAfterScan != nil {
		// Test-only deterministic barrier. Production never configures this hook.
		r.reservationAfterScan(model)
	}
	tScanned := time.Now()
	result := providerReservationScan{
		selected:     selected,
		candidates:   candidates,
		cacheTracker: r.cacheRouting,
		cacheMode:    r.cacheRoutingMode,
		lockWaitUS:   tLocked.Sub(tScanStart).Microseconds(),
		scanUS:       tScanned.Sub(tLocked).Microseconds(),
	}
	r.mu.RUnlock()
	return result
}
