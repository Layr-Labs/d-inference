package registry

import (
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Bounded dispatch plan — Routing v2 Phase 3 (identity retention).
//
// Prod gap (timeout route rows, 2026-08): failed requests carried
// candidate_count 86-401 with attempt indexes up to 9, yet every retry and
// speculative backup re-scanned the whole fleet from scratch
// (coordinator/api/dispatch.go → ReserveProviderEx). Candidates were never the
// deficit — identity retention was: by the time a retry scanned again, the
// herd had moved, the scan re-ranked the same overloaded boxes, and the
// request burned its first-content budget on rescan after rescan.
//
// The plan retains up to dispatchPlanMaxAlternates of the first-content-ranked
// NON-winner candidates from the SAME scan that selected the primary, plus
// full-pool aggregate counts for telemetry. It is strictly request-local
// state: *Provider pointers plus small value snapshots of the ranking terms,
// no registry-side maps, no TTLs, no background reaping — when the request
// ends, the plan is garbage. Consuming an entry later goes through
// ReserveNextFromPlan, which re-verifies identity (the registry must still map
// the entry's provider ID to the exact same *Provider — a reconnect creates a
// new object) and re-runs the FULL admission gate chain via the same helpers
// the scan uses, so a plan entry can never bypass a gate that a fresh scan
// would apply.
const dispatchPlanMaxAlternates = 8

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

// PlanEntry is the exported view of one retained alternate: the ranking and
// revalidation terms dispatch code needs for hedge timing and telemetry,
// captured at scan time. Estimates are scan-time values — ReserveNextFromPlan
// recomputes everything against live state before reserving.
type PlanEntry struct {
	FirstContent   FirstContentEstimate
	HealthMs       float64
	CapacityRateMs float64
	ProviderID     string
	// CostMs retains the legacy cost diagnostic; FirstContent carries the
	// expected/conservative predictions and service work used for ordering.
	CostMs float64
	// TTFTMs is the scan-time expected first-content estimate; RawTTFTMs
	// retains the old predictor diagnostic for calibration comparisons.
	TTFTMs    float64
	RawTTFTMs float64
	// StateMs is the slot-state penalty (0 = warm/running; large = cold load
	// ahead). ModelLoaded/SlotState carry the warm/idle detail.
	StateMs     float64
	ModelLoaded bool
	SlotState   string
	ChipFamily  string

	// Wave-2 quote enrichment (capacity_quotes.go). Confirmed is set by an
	// affirmative capacity_quote, Demoted by a negative quote, probe timeout,
	// or transport failure; both false = unprobed/legacy (ledger-scored,
	// mid-tier). The Quote* fields carry the provider's own live estimate and
	// are meaningful only while Confirmed.
	Confirmed bool
	Demoted   bool
	// QuoteTTFTP50/P90 are the quoted end-to-end TTFT distribution quantiles
	// (durations — the wire carries ms floats). P50 ranks confirmed choices;
	// hedge timing reads P90 via BestConfirmedBackup.
	QuoteTTFTP50 time.Duration
	QuoteTTFTP90 time.Duration
	// QuoteAvailableTokens is the quoted live token headroom of the admitting
	// gate; only high-confidence, current evidence can qualify a retry.
	QuoteAvailableTokens int64
	QuoteConfidence      string
	QuoteObservedAt      time.Time
	QuoteCapacitySeq     uint64
}

// planEntry pairs the exported view with the retained provider identity. The
// pointer is deliberately unexported: the ONLY way to turn an entry into a
// dispatchable provider is ReserveNextFromPlan's verify-and-reserve path.
type planEntry struct {
	evidenceQualified         bool
	forecastAt                time.Time
	cacheEvidenceWeight       float64
	cacheEstimatedTTFTSavedMs float64
	cacheAffinityEligible     bool
	provider                  *Provider
	view                      PlanEntry
}

// DispatchPlan is the request-local shortlist produced by
// ReserveProviderWithPlan. Entries retain first-content order and are consumed
// once each (cursor); quotes re-rank the unconsumed tail into confirmed,
// unprobed and demoted tiers, with first-content ordering within each tier.
// One full re-scan refresh is
// available for the plan's whole lifetime (RefreshDispatchPlan).
//
// Concurrency: a plan belongs to one request, but that request's retry loop,
// its speculative-backup goroutine, AND the probe collector
// (ProbePlanCandidates applies Confirm/Demote as quotes land) may touch it
// concurrently, so mu guards cursor/attempted/refreshUsed and the entries
// slice's ordering + quote state. mu is a LEAF lock: ReserveNextFromPlan
// acquires it strictly after r.mu, and no code path takes r.mu or p.mu while
// holding it.
type DispatchPlan struct {
	// Serialize consumers while quotes may still update the independent tail lock.
	reserveMu sync.Mutex
	mu        sync.Mutex
	model     string
	affinity  string
	entries   []planEntry
	cursor    int
	// attempted holds every provider this request has been bound to or has
	// passed over through this plan: the primary winner plus every entry the
	// cursor has visited, regardless of outcome. A refresh excludes them all —
	// re-offering a provider that was just tried or just failed a gate is
	// exactly the herd behavior the plan exists to avoid.
	attempted   map[string]struct{}
	refreshUsed bool

	// Full-pool aggregate counts from the scan that built the plan, as
	// progressively narrowing sets (eligible ⊇ admissible ⊇ deadline-feasible).
	eligible         int
	admissible       int
	deadlineFeasible int
}

// newDispatchPlan retains up to eight alternates by repeatedly applying the
// same first-content selector to the narrowed scan pool. Current identity,
// forecast, cache proof and physical admission are checked again on consumption.
func newDispatchPlan(model string, scan candidateScan, winner *routingCandidate) *DispatchPlan {
	plan := &DispatchPlan{
		model:     model,
		affinity:  scan.affinity,
		entries:   make([]planEntry, 0, dispatchPlanMaxAlternates),
		attempted: make(map[string]struct{}, dispatchPlanMaxAlternates+1),
		// Aggregate derivation from the scan tallies: capacity- and
		// TTFT-rejected providers cleared every structural gate first (the scan
		// counts them only after a successful snapshot), so they are eligible;
		// TTFT-rejected providers additionally passed capacity admission
		// (the ceiling is checked after buildCandidateWithReason succeeds), so
		// they are admissible; candidateCount passed everything.
		eligible:         scan.candidateCount + scan.capacityRejections + scan.ttftRejections,
		admissible:       scan.candidateCount + scan.ttftRejections,
		deadlineFeasible: scan.candidateCount,
	}
	if winner != nil {
		plan.attempted[winner.provider.ID] = struct{}{}
	}
	plan.entries = firstContentPlanEntries(scan.pool, winner, scan.affinity)

	return plan
}

// Model returns the model the plan was built for.
func (dp *DispatchPlan) Model() string {
	if dp == nil {
		return ""
	}
	return dp.model
}

// Len returns the number of retained alternates (consumed or not).
func (dp *DispatchPlan) Len() int {
	if dp == nil {
		return 0
	}
	return len(dp.entries)
}

// Remaining returns how many alternates the cursor has not yet visited.
func (dp *DispatchPlan) Remaining() int {
	if dp == nil {
		return 0
	}
	dp.mu.Lock()
	defer dp.mu.Unlock()
	return len(dp.entries) - dp.cursor
}

// PeekNext returns the next unconsumed entry's view without advancing the
// cursor, and false when the plan is exhausted. Inspection only — hedge
// timing reads BestConfirmedBackup, and consumption goes through
// ReserveNextFromPlan.
func (dp *DispatchPlan) PeekNext() (PlanEntry, bool) {
	if dp == nil {
		return PlanEntry{}, false
	}
	dp.mu.Lock()
	defer dp.mu.Unlock()
	if dp.cursor >= len(dp.entries) {
		return PlanEntry{}, false
	}
	return dp.entries[dp.cursor].view, true
}

// EligibleCount is the number of providers that cleared every structural,
// trait, and trust gate for this request at scan time (including those then
// rejected for capacity or the TTFT ceiling).
func (dp *DispatchPlan) EligibleCount() int {
	if dp == nil {
		return 0
	}
	return dp.eligible
}

// AdmissibleCount is the subset of EligibleCount that also passed live
// capacity admission at scan time.
func (dp *DispatchPlan) AdmissibleCount() int {
	if dp == nil {
		return 0
	}
	return dp.admissible
}

// DeadlineFeasibleCount is the subset of AdmissibleCount whose estimated TTFT
// also fit the per-request ceiling — the pool the selector actually ranked.
func (dp *DispatchPlan) DeadlineFeasibleCount() int {
	if dp == nil {
		return 0
	}
	return dp.deadlineFeasible
}

// RefreshUsed reports whether the plan's single full re-scan refresh has been
// consumed (a refreshed plan is born with it consumed).
func (dp *DispatchPlan) RefreshUsed() bool {
	if dp == nil {
		return true
	}
	dp.mu.Lock()
	defer dp.mu.Unlock()
	return dp.refreshUsed
}

// AttemptedProviderIDs returns a copy of every provider ID this plan has bound
// or visited, for callers composing exclusion sets across attempts.
func (dp *DispatchPlan) AttemptedProviderIDs() []string {
	if dp == nil {
		return nil
	}
	dp.mu.Lock()
	defer dp.mu.Unlock()
	ids := make([]string, 0, len(dp.attempted))
	for id := range dp.attempted {
		ids = append(ids, id)
	}
	return ids
}

// nextEntry advances the cursor by one and marks the entry attempted.
func (dp *DispatchPlan) nextEntry() (planEntry, bool) {
	dp.mu.Lock()
	defer dp.mu.Unlock()
	if dp.cursor >= len(dp.entries) {
		return planEntry{}, false
	}
	e := dp.entries[dp.cursor]
	dp.cursor++
	dp.attempted[e.view.ProviderID] = struct{}{}
	return e, true
}

// ReserveProviderWithPlan is ReserveProviderEx plus plan retention: identical
// selection and reservation semantics (it IS the same implementation —
// reserveProvider in scheduler.go), additionally returning the bounded
// DispatchPlan of provisional alternates from the same scan. The plan is nil
// whenever no provider was reserved.
func (r *Registry) ReserveProviderWithPlan(model string, pr *PendingRequest, excludeIDs ...string) (*Provider, RoutingDecision, *DispatchPlan) {
	return r.reserveProvider(model, pr, true, excludeIDs...)
}

// ReserveNextFromPlan snapshots every retained identity against current state,
// reapplies ownership/feasibility/version/decode preferences, and atomically
// revalidates the selected candidate before consuming its identity and debiting
// capacity. Each scan is bounded; cache proof and fresh quotes are evidence,
// never permission to skip the physical admission gates.
func (r *Registry) ReserveNextFromPlan(pr *PendingRequest, plan *DispatchPlan, excludeIDs ...string) (*Provider, RoutingDecision, []PlanSkip) {
	if pr == nil || pr.RequestID == "" || plan == nil || plan.model == "" {
		return nil, RoutingDecision{}, []PlanSkip{{Reason: PlanSkipExhausted}}
	}
	return r.reserveFirstContentFromPlan(pr, plan, excludeIDs...)
}

// RefreshDispatchPlan performs the plan's single full re-scan refresh: a fresh
// ReserveProviderWithPlan excluding every provider the exhausted plan already
// attempted (winner + every visited entry) plus the caller's exclusions. The
// returned plan is born with its refresh consumed, so a request chain gets at
// most one re-scan no matter how plans are threaded. Returns performed=false
// (and scans nothing) when the refresh was already used or plan is nil; a
// performed refresh that finds no provider returns a nil provider and nil
// plan with the failure RoutingDecision, exactly like ReserveProviderWithPlan.
func (r *Registry) RefreshDispatchPlan(pr *PendingRequest, plan *DispatchPlan, excludeIDs ...string) (p *Provider, decision RoutingDecision, fresh *DispatchPlan, performed bool) {
	if plan == nil {
		return nil, RoutingDecision{}, nil, false
	}
	plan.mu.Lock()
	if plan.refreshUsed {
		plan.mu.Unlock()
		return nil, RoutingDecision{Model: plan.model}, nil, false
	}
	plan.refreshUsed = true
	exclude := make([]string, 0, len(plan.attempted)+len(excludeIDs))
	for id := range plan.attempted {
		exclude = append(exclude, id)
	}
	plan.mu.Unlock()
	exclude = append(exclude, excludeIDs...)

	p, decision, fresh = r.reserveProvider(plan.model, pr, true, exclude...)
	if fresh != nil {
		fresh.mu.Lock()
		fresh.refreshUsed = true
		fresh.mu.Unlock()
	}
	return p, decision, fresh, true
}

// planEntryRank orders the unconsumed tail into quote tiers: provider-confirmed
// entries first (their quotes are the freshest state we have), unprobed and
// legacy entries mid (today's ledger estimate — neither endorsed nor refuted),
// demoted entries last (a live refusal, timeout, or dead transport outranks any
// scan-time cost — but the entry stays consumable as a last resort because
// ReserveNextFromPlan re-gates everything anyway, and a stale-negative quote
// must not permanently strand a provider a refresh would re-offer).
func planEntryRank(v PlanEntry) int {
	switch {
	case v.Demoted:
		return 2
	case v.Confirmed:
		return 0
	default:
		return 1
	}
}

// resortTailLocked orders quote tiers using the same first-content band and
// service-work selector within each tier. Entries already consumed are history.
// Caller holds the leaf dp.mu; this helper never reads mutable provider state.
func (dp *DispatchPlan) resortTailLocked() {
	tail := dp.entries[dp.cursor:]
	remaining := append([]planEntry(nil), tail...)
	for i := range tail {
		bestTier := 3
		for _, entry := range remaining {
			bestTier = min(bestTier, planEntryRank(entry.view))
		}
		candidates := make([]*routingCandidate, 0, len(remaining))
		positions := make(map[*routingCandidate]int, len(remaining))
		for j, entry := range remaining {
			if planEntryRank(entry.view) != bestTier {
				continue
			}
			forecast := entry.view.FirstContent
			if entry.view.Confirmed && entry.view.QuoteTTFTP50 > 0 {
				forecast.ExpectedMs = max(forecast.ExpectedMs, float64(entry.view.QuoteTTFTP50)/float64(time.Millisecond)+forecast.RestoreMs)
			}
			candidate := &routingCandidate{provider: entry.provider, costMs: entry.view.CostMs, firstContent: forecast,
				cacheEvidenceWeight: entry.cacheEvidenceWeight, cacheEstimatedTTFTSavedMs: entry.cacheEstimatedTTFTSavedMs, cacheAffinityEligible: entry.cacheAffinityEligible,
				breakdown: costBreakdown{HealthMs: entry.view.HealthMs, CapacityRateMs: entry.view.CapacityRateMs}}
			candidates = append(candidates, candidate)
			positions[candidate] = j
		}
		chosen, _, _, _ := selectRoutingCandidateWithAffinity(candidates, dp.affinity)
		j := positions[chosen]
		tail[i] = remaining[j]
		remaining = append(remaining[:j], remaining[j+1:]...)
	}
}

// ConfirmEntry records an affirmative capacity_quote on the named unconsumed
// entry: the provider's live TTFT quantiles, token headroom, and confidence
// replace nothing (the scan-time estimates stay for telemetry) but ride
// alongside for hedge timing, and the entry is promoted into the confirmed
// tier. A no-op when the entry was already consumed or is not in the plan —
// a quote that raced the dispatch loop carries no ordering work to do.
func (dp *DispatchPlan) ConfirmEntry(providerID string, quote *protocol.CapacityQuoteMessage) {
	dp.confirmEntryAt(providerID, quote, time.Now())
}

func (dp *DispatchPlan) confirmEntryAt(providerID string, quote *protocol.CapacityQuoteMessage, observedAt time.Time) {
	if dp == nil || quote == nil {
		return
	}
	dp.mu.Lock()
	defer dp.mu.Unlock()
	for i := dp.cursor; i < len(dp.entries); i++ {
		v := &dp.entries[i].view
		if v.ProviderID != providerID {
			continue
		}
		v.Confirmed = true
		v.Demoted = false
		v.QuoteTTFTP50 = time.Duration(quote.TTFTP50MS * float64(time.Millisecond))
		v.QuoteTTFTP90 = time.Duration(quote.TTFTP90MS * float64(time.Millisecond))
		v.QuoteAvailableTokens = quote.AvailableTokenBudget
		v.QuoteConfidence = quote.Confidence
		v.QuoteObservedAt = observedAt
		v.QuoteCapacitySeq = quote.CapacitySeq
		dp.resortTailLocked()
		return
	}
}

// DemoteEntry pushes the named unconsumed entry into the last-resort tier —
// the outcome for a negative quote, a probe timeout, or a transport failure.
// Demotion wins over a prior confirmation (it is always the fresher signal:
// quotes resolve their entry exactly once per probe, so a demote after a
// confirm can only come from a later event such as a disconnect).
func (dp *DispatchPlan) DemoteEntry(providerID string) {
	if dp == nil {
		return
	}
	dp.mu.Lock()
	defer dp.mu.Unlock()
	for i := dp.cursor; i < len(dp.entries); i++ {
		v := &dp.entries[i].view
		if v.ProviderID != providerID {
			continue
		}
		v.Demoted = true
		v.Confirmed = false
		dp.resortTailLocked()
		return
	}
}

// BestConfirmedBackup returns the best retained, fresh high-confidence quote
// for hedge timing. Reservation independently revalidates its session, sequence,
// current capacity and original deadline before dispatch.
func (dp *DispatchPlan) BestConfirmedBackup() (providerID string, ttftP90 time.Duration, ok bool) {
	if dp == nil {
		return "", 0, false
	}
	dp.mu.Lock()
	defer dp.mu.Unlock()
	now := time.Now()
	for i := dp.cursor; i < len(dp.entries); i++ {
		entry := dp.entries[i]
		v := entry.view
		age := now.Sub(entry.forecastAt)
		if !entry.evidenceQualified || entry.forecastAt.IsZero() || age < 0 ||
			time.Duration(v.FirstContent.CapacityAgeMs)*time.Millisecond+age > firstContentFreshness ||
			time.Duration(v.FirstContent.PerformanceAgeMs)*time.Millisecond+age > firstContentPerformanceFreshness {
			continue
		}
		if v.Confirmed && !v.Demoted && v.QuoteConfidence == protocol.CapacityConfidenceHigh &&
			!v.QuoteObservedAt.IsZero() && !now.Before(v.QuoteObservedAt) && now.Sub(v.QuoteObservedAt) <= firstContentFreshness {
			p90 := max(time.Duration(v.FirstContent.ConservativeMs*float64(time.Millisecond)), v.QuoteTTFTP90+time.Duration(v.FirstContent.RestoreMs*float64(time.Millisecond)))
			return v.ProviderID, p90, true
		}
	}
	return "", 0, false
}

// probeTargets snapshots the unconsumed, not-yet-quoted entries for the probe
// fanout (ProbePlanCandidates). Copies of the planEntry pairs, taken under
// dp.mu, so the fanout can inspect providers and mint probes without holding
// the plan lock while entries concurrently re-rank.
func (dp *DispatchPlan) probeTargets() []planEntry {
	if dp == nil {
		return nil
	}
	dp.mu.Lock()
	defer dp.mu.Unlock()
	targets := make([]planEntry, 0, len(dp.entries)-dp.cursor)
	for _, e := range dp.entries[dp.cursor:] {
		if e.view.Confirmed || e.view.Demoted {
			continue
		}
		targets = append(targets, e)
	}
	return targets
}
