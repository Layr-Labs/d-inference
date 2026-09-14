package dispatchplan

import (
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// planEntryRank orders the unconsumed tail into quote tiers: provider-confirmed
// entries first (their quotes are the freshest state we have), unprobed and
// legacy entries mid (today's ledger estimate — neither endorsed nor refuted),
// demoted entries last (a live refusal, timeout, or dead transport outranks any
// scan-time cost — but the entry stays consumable as a last resort because
// ReserveNextFromPlan re-gates everything anyway, and a stale-negative quote
// must not permanently strand a provider a refresh would re-offer).
func planEntryRank(v Entry) int {
	switch {
	case v.Demoted:
		return 2
	case v.Confirmed:
		return 0
	default:
		return 1
	}
}

// resortTailLocked re-ranks the unconsumed entries after a quote outcome:
// tier first, ascending scan-time cost within the tier. Cost must be an
// explicit secondary key (not left to sort stability): entries change tier in
// quote-arrival order, so by the time a cheap entry is confirmed a costlier
// one may already sit in the confirmed tier ahead of it — a stability-only
// sort would freeze that inversion and BestConfirmedBackup would return the
// wrong entry. Entries the cursor already consumed are never moved — they are
// history (attempted set, telemetry), not candidates. Caller holds dp.mu.
func (dp *Plan[C]) resortTailLocked() {
	tail := dp.entries[dp.cursor:]
	sort.SliceStable(tail, func(i, j int) bool {
		ri, rj := planEntryRank(tail[i].View), planEntryRank(tail[j].View)
		if ri != rj {
			return ri < rj
		}
		return tail[i].View.CostMs < tail[j].View.CostMs
	})
}

// ConfirmEntry records an affirmative capacity_quote on the named unconsumed
// entry: the provider's live TTFT quantiles, token headroom, and confidence
// replace nothing (the scan-time estimates stay for telemetry) but ride
// alongside for hedge timing, and the entry is promoted into the confirmed
// tier. A no-op when the entry was already consumed or is not in the plan —
// a quote that raced the dispatch loop carries no ordering work to do.
func (dp *Plan[C]) ConfirmEntry(providerID string, quote *protocol.CapacityQuoteMessage) {
	if dp == nil || quote == nil {
		return
	}
	dp.mu.Lock()
	defer dp.mu.Unlock()
	for i := dp.cursor; i < len(dp.entries); i++ {
		v := &dp.entries[i].View
		if v.ProviderID != providerID {
			continue
		}
		v.Confirmed = true
		v.Demoted = false
		v.QuoteTTFTP50 = time.Duration(quote.TTFTP50MS * float64(time.Millisecond))
		v.QuoteTTFTP90 = time.Duration(quote.TTFTP90MS * float64(time.Millisecond))
		v.QuoteAvailableTokens = quote.AvailableTokenBudget
		v.QuoteConfidence = quote.Confidence
		dp.resortTailLocked()
		return
	}
}

// DemoteEntry pushes the named unconsumed entry into the last-resort tier —
// the outcome for a negative quote, a probe timeout, or a transport failure.
// Demotion wins over a prior confirmation (it is always the fresher signal:
// quotes resolve their entry exactly once per probe, so a demote after a
// confirm can only come from a later event such as a disconnect).
func (dp *Plan[C]) DemoteEntry(providerID string) {
	if dp == nil {
		return
	}
	dp.mu.Lock()
	defer dp.mu.Unlock()
	for i := dp.cursor; i < len(dp.entries); i++ {
		v := &dp.entries[i].View
		if v.ProviderID != providerID {
			continue
		}
		v.Demoted = true
		v.Confirmed = false
		dp.resortTailLocked()
		return
	}
}

// BestConfirmedBackup returns the lowest-scan-cost unconsumed entry whose
// quote confirmed admissibility, plus its quoted TTFT p90 — the hedge
// scheduler's backup_ttft_q90 input (hedge_schedule.go). ok=false when no
// confirmed entry remains; callers then fall back to the coordinator floor.
// The tail is tier-sorted with cost order preserved inside the confirmed
// tier, so the first confirmed entry IS the lowest-cost one.
func (dp *Plan[C]) BestConfirmedBackup() (providerID string, ttftP90 time.Duration, ok bool) {
	if dp == nil {
		return "", 0, false
	}
	dp.mu.Lock()
	defer dp.mu.Unlock()
	for i := dp.cursor; i < len(dp.entries); i++ {
		if v := dp.entries[i].View; v.Confirmed {
			return v.ProviderID, v.QuoteTTFTP90, true
		}
	}
	return "", 0, false
}
