package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/dispatchplan"
)

const dispatchPlanMaxAlternates = dispatchplan.MaxAlternates

// PlanSkipReason is the bounded reason a plan entry was passed over by
// ReserveNextFromPlan. Bounded (never free-form) so it can feed route-row
// taxonomy and metric tags without cardinality risk.
type PlanSkipReason string

const (
	// PlanSkipStaleSession: the registry no longer maps the entry's provider
	// ID to the same *Provider object — the session disconnected (and possibly
	// reconnected as a new object). The retained identity is invalid.
	PlanSkipStaleSession PlanSkipReason = "stale_session"
	// PlanSkipExcluded: the caller's exclusion set (previous attempts,
	// speculative peers) or pr.ExcludedProviderIDs names this provider.
	PlanSkipExcluded PlanSkipReason = "excluded"
	// PlanSkipGateRejected: the provider is still the same session but no
	// longer clears the full admission gate chain (structural/trait/trust
	// gates, capacity admission, TTFT ceiling) against CURRENT state.
	PlanSkipGateRejected PlanSkipReason = "gate_rejected"
	// PlanSkipVersionAvoided: a version-diverse retry (pr.Traits.AvoidVersion)
	// reserved an entry running a DIFFERENT binary version, so this entry —
	// live on exactly the avoided version — was passed over. Soft by
	// construction: recorded only when diversity actually won; when no
	// diverse entry is admissible the same entries are revisited and reserve
	// or fail with their own reasons.
	PlanSkipVersionAvoided PlanSkipReason = "version_avoided"
	// PlanSkipExhausted: no entries remain in the plan. Plan-level, carried
	// with an empty ProviderID as the terminal element of the skip list.
	PlanSkipExhausted PlanSkipReason = "exhausted"
)

// PlanSkip records one passed-over plan entry and why.
type PlanSkip struct {
	ProviderID string
	Reason     PlanSkipReason
}

// PlanEntry is the immutable scan view enriched by capacity quotes.
// ReserveNextFromPlan revalidates all admission terms against live state.
type PlanEntry = dispatchplan.Entry

// planEntry keeps retained connections private to the reservation transaction.
type planEntry struct {
	provider *Provider
	view     PlanEntry
}

// DispatchPlan retains bounded request-local alternates, quote ranking and one
// refresh. Its private owner serializes consumption and quote settlement; live
// identity and admission checks remain in Registry.ReserveNextFromPlan.
type DispatchPlan struct{ state dispatchplan.Plan[*Provider] }

func (dp *DispatchPlan) owned() *dispatchplan.Plan[*Provider] {
	if dp == nil {
		return nil
	}
	return &dp.state
}

// Model returns the model the plan was built for.
func (dp *DispatchPlan) Model() string { return dp.owned().Model() }

// Len returns the number of retained alternates (consumed or not).
func (dp *DispatchPlan) Len() int { return dp.owned().Len() }

// Remaining returns how many alternates the cursor has not yet visited.
func (dp *DispatchPlan) Remaining() int { return dp.owned().Remaining() }

// PeekNext returns the next unconsumed entry's view without advancing the
// cursor, and false when the plan is exhausted. Inspection only — hedge
// timing reads BestConfirmedBackup, and consumption goes through
// ReserveNextFromPlan.
func (dp *DispatchPlan) PeekNext() (PlanEntry, bool) { return dp.owned().PeekNext() }

// EligibleCount is the number of providers that cleared every structural,
// trait, and trust gate for this request at scan time (including those then
// rejected for capacity or the TTFT ceiling).
func (dp *DispatchPlan) EligibleCount() int { return dp.owned().EligibleCount() }

// AdmissibleCount is the subset of EligibleCount that also passed live
// capacity admission at scan time.
func (dp *DispatchPlan) AdmissibleCount() int { return dp.owned().AdmissibleCount() }

// DeadlineFeasibleCount is the subset of AdmissibleCount whose estimated TTFT
// also fit the per-request ceiling — the pool the selector actually ranked.
func (dp *DispatchPlan) DeadlineFeasibleCount() int { return dp.owned().DeadlineFeasibleCount() }

// RefreshUsed reports whether the plan's single full re-scan refresh has been
// consumed (a refreshed plan is born with it consumed).
func (dp *DispatchPlan) RefreshUsed() bool { return dp.owned().RefreshUsed() }

// AttemptedProviderIDs returns a copy of every provider ID this plan has bound
// or visited, for callers composing exclusion sets across attempts.
func (dp *DispatchPlan) AttemptedProviderIDs() []string { return dp.owned().AttemptedProviderIDs() }

// ConfirmEntry records an affirmative capacity_quote on the named unconsumed
// entry: the provider's live TTFT quantiles, token headroom, and confidence
// replace nothing (the scan-time estimates stay for telemetry) but ride
// alongside for hedge timing, and the entry is promoted into the confirmed
// tier. A no-op when the entry was already consumed or is not in the plan —
// a quote that raced the dispatch loop carries no ordering work to do.
func (dp *DispatchPlan) ConfirmEntry(providerID string, quote *protocol.CapacityQuoteMessage) {
	dp.owned().ConfirmEntry(providerID, quote)
}

// DemoteEntry pushes the named unconsumed entry into the last-resort tier —
// the outcome for a negative quote, a probe timeout, or a transport failure.
// Demotion wins over a prior confirmation (it is always the fresher signal:
// quotes resolve their entry exactly once per probe, so a demote after a
// confirm can only come from a later event such as a disconnect).
func (dp *DispatchPlan) DemoteEntry(providerID string) { dp.owned().DemoteEntry(providerID) }

// BestConfirmedBackup returns the lowest-scan-cost unconsumed entry whose
// quote confirmed admissibility, plus its quoted TTFT p90 — the hedge
// scheduler's backup_ttft_q90 input (hedge_schedule.go). ok=false when no
// confirmed entry remains; callers then fall back to the coordinator floor.
// The tail is tier-sorted with cost order preserved inside the confirmed
// tier, so the first confirmed entry IS the lowest-cost one.
func (dp *DispatchPlan) BestConfirmedBackup() (string, time.Duration, bool) {
	return dp.owned().BestConfirmedBackup()
}

// nextEntry claims one identity for the live reservation path.
func (dp *DispatchPlan) nextEntry() (planEntry, bool) {
	entry, ok := dp.state.Next()
	return planEntry{provider: entry.Connection, view: entry.View}, ok
}
