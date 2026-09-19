package registry

import "bytes"

// This fence lives only as long as one request's bounded dispatch plan. Neither
// the authenticated account nor the physical machine identity is telemetry.
type accountAffinityPlanFence struct {
	enabled bool
	account string
	config  AccountAffinityConfig
	owner   string
	self    bool
	prefer  bool
}

func (dp *DispatchPlan) initAccountAffinity(scan candidateScan, requests []*PendingRequest) {
	if len(requests) == 0 || requests[0] == nil ||
		scan.accountAffinityConfig.Mode != AccountAffinityOn || !scan.accountAffinity.Applied {
		return
	}
	dp.affinity = accountAffinityPlanFence{
		enabled: true,
		account: requests[0].ConsumerKey,
		config:  scan.accountAffinityConfig,
		owner:   requests[0].OwnerAccountID,
		self:    requests[0].SelfRouteOnly,
		prefer:  requests[0].PreferOwner,
	}
}

// A changed account/config must not inherit an earlier account's HRW order.
// Restore the original quote/cost policy on the same bounded tail instead.
// Called under the registry commit lock; dp.mu stays a leaf lock.
func (dp *DispatchPlan) prepareAccountAffinity(pr *PendingRequest, cfg AccountAffinityConfig) bool {
	dp.mu.Lock()
	defer dp.mu.Unlock()
	if !dp.affinity.enabled {
		return false
	}
	if pr.ConsumerKey != dp.affinity.account || pr.Model != dp.model ||
		cfg != dp.affinity.config || pr.RequiresVision || pr.SelfRouteOnly != dp.affinity.self ||
		pr.PreferOwner != dp.affinity.prefer || pr.OwnerAccountID != dp.affinity.owner {
		dp.affinity.enabled = false
		dp.resortTailLocked()
		return false
	}
	return true
}

func planEntryFromCandidate(c *routingCandidate) planEntry {
	return planEntry{
		provider:         c.provider,
		affinityIdentity: c.snapshot.affinityIdentity,
		affinityScore:    c.accountAffinityScore,
		affinityRanked:   c.accountAffinityRanked,
		affinityEligible: c.accountAffinityEligible,
		view: PlanEntry{
			ProviderID:  c.provider.ID,
			CostMs:      c.costMs,
			TTFTMs:      c.breakdown.TTFTMs,
			RawTTFTMs:   c.breakdown.RawTTFTMs,
			StateMs:     c.breakdown.StateMs,
			ModelLoaded: c.snapshot.modelLoaded,
			SlotState:   c.snapshot.slotState,
			ChipFamily:  c.snapshot.chipFamily,
		},
	}
}

// Keep ready backups before temporarily affinity-infeasible identities. A run
// of eight busy high-HRW machines must not crowd every known-ready alternate
// out of the bounded plan. Spare slots can still retain busy identities for
// live recovery, and the final retained set is restored to HRW order.
func (dp *DispatchPlan) retainEntryBefore(a, b planEntry) bool {
	if dp.affinity.enabled && a.affinityEligible != b.affinityEligible {
		return a.affinityEligible
	}
	return dp.entryBefore(a, b, false)
}

// Positive quotes do not scramble account affinity in arrival order. Negative
// quotes remain a last-resort tier; ordering within each tier remains HRW.
// Construction passes quotes=false because no quote has arrived yet.
func (dp *DispatchPlan) entryBefore(a, b planEntry, quotes bool) bool {
	if !dp.affinity.enabled {
		if quotes && planEntryRank(a.view) != planEntryRank(b.view) {
			return planEntryRank(a.view) < planEntryRank(b.view)
		}
		return a.view.CostMs < b.view.CostMs
	}
	if quotes && a.view.Demoted != b.view.Demoted {
		return !a.view.Demoted
	}
	if a.affinityRanked != b.affinityRanked {
		return a.affinityRanked
	}
	if a.affinityRanked {
		if cmp := bytes.Compare(a.affinityScore[:], b.affinityScore[:]); cmp != 0 {
			return cmp > 0
		}
		if a.affinityIdentity != b.affinityIdentity {
			return a.affinityIdentity.before(b.affinityIdentity)
		}
		return a.view.ProviderID < b.view.ProviderID
	}
	return a.view.CostMs < b.view.CostMs
}

// remainingEntries is a bounded copy: never hold dp.mu while inspecting live
// provider state. Quote updates and another retry may proceed independently.
func (dp *DispatchPlan) remainingEntries() []planEntry {
	dp.mu.Lock()
	defer dp.mu.Unlock()
	return append([]planEntry(nil), dp.entries[dp.cursor:]...)
}

// claimEntry consumes exactly one named entry without discarding an earlier
// alternate that was temporarily busy. Concurrent hedge/retry consumers cannot
// reserve the same retained entry: only one can claim it under this leaf lock.
func (dp *DispatchPlan) claimEntry(id string) (planEntry, bool) {
	dp.mu.Lock()
	defer dp.mu.Unlock()
	for i := dp.cursor; i < len(dp.entries); i++ {
		if dp.entries[i].view.ProviderID != id {
			continue
		}
		entry := dp.entries[i]
		copy(dp.entries[dp.cursor+1:i+1], dp.entries[dp.cursor:i])
		dp.entries[dp.cursor] = entry
		dp.cursor++
		dp.attempted[id] = struct{}{}
		return entry, true
	}
	return planEntry{}, false
}

type accountAffinityPlanGuard struct {
	config             AccountAffinityConfig
	prefer             bool
	softRejected       bool
	checkedLoadDelayMs float64
}

func (g *accountAffinityPlanGuard) admits(entry planEntry, c *routingCandidate, pr *PendingRequest) bool {
	// Even the legacy fallback cannot apply a retained physical identity after
	// the same session is rebound to a different attested machine.
	if entry.affinityIdentity != c.snapshot.affinityIdentity {
		return false
	}
	// Called under the same p.mu as the pending debit. Carry this newly checked
	// same-machine load increment into telemetry instead of the earlier shortlist
	// snapshot, or a latency difference against some other physical machine.
	g.checkedLoadDelayMs = accountAffinityLoadDelayMs(c)
	g.softRejected = g.prefer && !accountAffinityFeasible(c, pr, g.config)
	return !g.softRejected
}
