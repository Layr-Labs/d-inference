package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/routingcost"
)

// ReserveProviderWithPlan is ReserveProviderEx plus plan retention: identical
// selection and reservation semantics (it IS the same implementation —
// reserveProvider in reservation.go), additionally returning the bounded
// DispatchPlan of provisional alternates from the same scan. The plan is nil
// whenever no provider was reserved.
func (r *Registry) ReserveProviderWithPlan(model string, pr *PendingRequest, excludeIDs ...string) (*Provider, RoutingDecision, *DispatchPlan) {
	return r.reserveProvider(model, pr, true, excludeIDs...)
}

// ReserveNextFromPlan consumes plan entries in cost order until one passes the
// full, CURRENT admission gate chain, reserving it atomically
// (addPendingLocked) exactly like the primary reservation. Entries that fail
// are skipped with a bounded reason; the skip list (terminated by an
// "exhausted" element when the plan runs out) is returned for telemetry and
// for the caller's refresh decision.
//
// Revalidation deliberately reuses the SAME helpers the scan uses — never a
// copied eligibility switch:
//   - identity: r.providers[id] must still be the exact retained *Provider
//     (a reconnect registers a new object under the same ID — its slot state,
//     trust, and capacity are a stranger's; see Register/Disconnect);
//   - snapshotProviderIntoLockedEx → providerPassesRoutingGatesLocked (every
//     structural/privacy/cooldown/trait gate);
//   - buildCandidateWithReason (slot state, concurrency headroom, thermal,
//     hardware fit, freeMemoryAdmits — including the in-flight pending debit
//     and the budget clamp) plus the same TTFT-ceiling condition the scan
//     enforces;
//   - providerCanAdmitLockedEx under p.mu, the same final admit re-check
//     ReserveProviderEx runs (no fail-open breaker carry here: plan entries
//     are alternates, and a breaker that opened since the scan should skip
//     the entry — the caller's refresh re-runs the full scan, whose fail-open
//     valve still protects the all-providers-broken case).
//
// Ledger note (why plan reservations cannot double-spend a heartbeat budget):
// each entry is re-snapshotted, re-costed, admit-checked and debited inside
// ONE p.mu section (exactly like commitProviderReservation), so
// freeMemoryAdmits charges every pending request admitted since the plan was
// built (fillSnapshotPendingAndPool → coordinatorExtra / pooledBudgetAdmits)
// and no concurrent commit can slip between the check and the debit. r.mu is
// held for reading across the loop (identity checks against r.providers stay
// valid); the global commit mode takes it for writing instead. See the ledger
// rationale on reserveProvider's pending-debit path in reservation.go.
//
// Version-diverse retry (SOFT — parity with scanCandidatesLocked's
// post-candidate AvoidVersion narrowing): when pr.Traits.AvoidVersion is set,
// consumption is a two-pass walk. Pass 1 visits the plan in cost order but
// DEFERS every entry whose provider's LIVE reported version equals the
// avoided one — read via providerVersion under p.mu during this
// revalidation, never a scan-time copy, because the provider may have
// upgraded (or rolled back onto the broken build) since the plan was built.
// Pass 2 revisits the deferred entries in the same order only when no
// diverse entry reserved, so diversity never fails closed: a pool that is
// all-avoided-version behaves exactly as if AvoidVersion were empty, just as
// the scan keeps its full pool when the diverse set is empty.
//
// The Phase-0 shadow TTFT evaluation is intentionally not recomputed for plan
// reservations: it is observational primary-selection telemetry, and the plan
// path is the retry/hedge lane.
func (r *Registry) ReserveNextFromPlan(pr *PendingRequest, plan *DispatchPlan, excludeIDs ...string) (*Provider, RoutingDecision, []PlanSkip) {
	if pr == nil || pr.RequestID == "" || plan == nil || plan.Model() == "" {
		return nil, RoutingDecision{}, []PlanSkip{{Reason: PlanSkipExhausted}}
	}
	model := plan.Model()
	if pr.Model == "" {
		pr.Model = model
	}
	if pr.RequestedMaxTokens <= 0 {
		pr.RequestedMaxTokens = defaultRequestedMaxTokens
	}
	exclude := make(map[string]struct{}, len(excludeIDs)+len(pr.ExcludedProviderIDs))
	for _, id := range excludeIDs {
		exclude[id] = struct{}{}
	}
	for _, id := range pr.ExcludedProviderIDs {
		exclude[id] = struct{}{}
	}
	allowedSerials := make(map[string]struct{}, len(pr.AllowedProviderSerials))
	for _, serial := range pr.AllowedProviderSerials {
		allowedSerials[serial] = struct{}{}
	}
	enforceTTFT := pr.MaxTTFTMs > 0 && !pr.RequiresVision

	var skips []PlanSkip
	lock := r.commitLock("commit_plan")
	lock.lock()
	defer lock.unlock()

	// tryReserve runs the full CURRENT gate chain against one identity-checked
	// entry and, on success, commits the reservation. Failure appends the
	// bounded gate_rejected skip.
	tryReserve := func(entry planEntry) (*Provider, RoutingDecision, bool) {
		id := entry.view.ProviderID
		p := entry.provider
		skip := func(reason PlanSkipReason) {
			skips = append(skips, PlanSkip{ProviderID: id, Reason: reason})
		}
		// Scan-order pre-snapshot filters (scanCandidatesLocked): exclusive
		// self-route ownership and the attested-serial allowlist.
		owned := providerOwnedBy(p, pr.OwnerAccountID)
		if pr.SelfRouteOnly && !owned {
			skip(PlanSkipGateRejected)
			return nil, RoutingDecision{}, false
		}
		if len(allowedSerials) > 0 && !providerMatchesAllowedSerial(p, allowedSerials) {
			skip(PlanSkipGateRejected)
			return nil, RoutingDecision{}, false
		}
		relaxTrust := owned && (pr.SelfRouteOnly || pr.PreferOwner)

		candidate := r.commitPlanEntry(p, model, pr, relaxTrust, enforceTTFT)
		if candidate == nil {
			skip(PlanSkipGateRejected)
			return nil, RoutingDecision{}, false
		}

		if !routingcost.SlotStateModelLoaded(candidate.snapshot.SlotState) {
			r.RecordWarmPoolColdDispatch(model)
		}
		// Same calibrator-join rule as the primary path: warm text dispatches
		// only (see reserveProvider).
		bd := candidate.breakdown
		if !pr.RequiresVision && bd.RawTTFTMs > 0 && bd.StateMs == 0 {
			routingPolicy.NotePrediction(pr.RequestID, pr.Attempt, model, candidate.snapshot.ChipFamily, bd.RawTTFTMs)
		}
		// Winner-specific fields only: the scan tallies belong to the plan
		// (EligibleCount/…), not to this per-entry revalidation, so the count
		// fields stay zero rather than repeating stale scan-time numbers.
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
			CapacityRateMs:     bd.CapacityRateMs,
			CapacityRejectRate: candidate.capacityRejectRate,
			EffectiveQueue:     candidate.effectiveQueue,
			TTFTMs:             bd.TTFTMs,
			EffectiveTPS:       candidate.effectiveTPS,
			StaticTPS:          candidate.snapshot.DecodeTPS,
		}
		return p, decision, true
	}

	// Pass 1: cost order, deferring live avoided-version entries (see the
	// version-diverse retry rationale in the doc comment).
	avoid := pr.Traits.AvoidVersion
	var deferred []planEntry
	for {
		entry, ok := plan.nextEntry()
		if !ok {
			break
		}
		id := entry.view.ProviderID
		if _, excluded := exclude[id]; excluded {
			skips = append(skips, PlanSkip{ProviderID: id, Reason: PlanSkipExcluded})
			continue
		}
		if cur, live := r.providers[id]; !live || cur != entry.provider {
			skips = append(skips, PlanSkip{ProviderID: id, Reason: PlanSkipStaleSession})
			continue
		}
		if avoid != "" && providerVersion(entry.provider) == avoid {
			deferred = append(deferred, entry)
			continue
		}
		if p, decision, ok := tryReserve(entry); ok {
			// Diversity won: the deferred same-version entries were passed
			// over for this consumption — record them for telemetry.
			for _, d := range deferred {
				skips = append(skips, PlanSkip{ProviderID: d.view.ProviderID, Reason: PlanSkipVersionAvoided})
			}
			return p, decision, skips
		}
	}
	// Pass 2: no diverse entry was admissible — fall back to the avoided
	// version rather than failing closed. The pass-1 identity checks remain
	// valid: r.providers cannot change while r.mu is held in either mode.
	for _, entry := range deferred {
		if p, decision, ok := tryReserve(entry); ok {
			return p, decision, skips
		}
	}
	skips = append(skips, PlanSkip{Reason: PlanSkipExhausted})
	return nil, RoutingDecision{Model: model}, skips
}

// commitPlanEntry snapshots, checks and debits one identity-verified alternate
// under a single provider lock. Caller holds the registry commit lock, preserving
// session identity. Rejections leave no pending debit; telemetry runs in the
// caller only after this method releases p.mu.
func (r *Registry) commitPlanEntry(p *Provider, model string, pr *PendingRequest, relaxTrust, enforceTTFT bool) *routingCandidate {
	p.mu.Lock()
	defer p.mu.Unlock()

	// Lock waits consume the request clock. Refresh after both locks, before
	// admission, and tighten an enabled TTFT ceiling to the remaining budget.
	now := time.Now()
	if !pr.RefreshFirstContentBudget(now) {
		return nil
	}
	var snap routingSnapshot
	if ok, _ := r.snapshotProviderIntoPLockedEx(&snap, p, model, pr.Traits, relaxTrust, false, now); !ok {
		return nil
	}
	candidate, _, ok := r.buildCandidateWithReason(snap, pr, now)
	if !ok {
		return nil
	}
	if enforceTTFT && snap.HasBackendCapacity && candidate.breakdown.TTFTMs > pr.MaxTTFTMs {
		return nil
	}
	if !r.providerCanAdmitLockedEx(p, model, pr.Traits, relaxTrust, false, now) ||
		(pr.RequiresVision && !r.providerServesVisionModelLocked(p, model, relaxTrust)) {
		return nil
	}
	// Claim the half-open capacity probe in the existing p.mu -> gate.mu order.
	if !r.tryClaimCapacityProbe(p, model, now) {
		return nil
	}
	pr.ProviderID = p.ID
	p.addPendingLocked(pr)
	if p.Status != StatusUntrusted && p.Status != StatusOffline {
		p.Status = StatusServing
	}
	return candidate
}
