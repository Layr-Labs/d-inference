package registry

import (
	"sort"
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
// The plan retains up to dispatchPlanMaxAlternates of the lowest-cost
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
	ProviderID string
	// CostMs is the candidate's full routing cost at scan time (same quantity
	// selectRoutingCandidate ranked by).
	CostMs float64
	// TTFTMs is the calibrated scan-time TTFT estimate (0 when the provider
	// reports no BackendCapacity — unreliable, matching the scan's ceiling
	// exemption). RawTTFTMs is the uncalibrated formula value alongside.
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
	// (durations — the wire carries ms floats). P50 is telemetry view only;
	// production hedge timing reads P90 via BestConfirmedBackup.
	QuoteTTFTP50 time.Duration
	QuoteTTFTP90 time.Duration
	// QuoteAvailableTokens is the quoted live token headroom of the admitting
	// gate; QuoteConfidence is protocol.CapacityConfidenceHigh/Low. Telemetry
	// view; no production consumer reads these off the plan today.
	QuoteAvailableTokens int64
	QuoteConfidence      string
}

// planEntry pairs the exported view with the retained provider identity. The
// pointer is deliberately unexported: the ONLY way to turn an entry into a
// dispatchable provider is ReserveNextFromPlan's verify-and-reserve path.
type planEntry struct {
	provider *Provider
	view     PlanEntry
}

// DispatchPlan is the request-local shortlist produced by
// ReserveProviderWithPlan. Entries are born ordered by ascending scan-time
// cost and consumed once each (cursor); quote outcomes re-rank the UNCONSUMED
// tail into confirmed → unprobed/legacy → demoted tiers (cost order preserved
// within each tier — see resortTailLocked); one full re-scan refresh is
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
	mu      sync.Mutex
	model   string
	entries []planEntry
	cursor  int
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

// newDispatchPlan builds the plan from the scan that selected winner. One
// bounded pass over the already-built pool: it keeps the
// dispatchPlanMaxAlternates lowest-cost non-winner candidates via insertion
// into a fixed-capacity slice (O(n·8) comparisons, no full-pool sort, no
// full-pool copy — only the ≤8 retained entries copy their ranking terms).
// The scan pool is immutable; live provider identity/state is revalidated when
// an entry is consumed.
func newDispatchPlan(model string, scan candidateScan, winner *routingCandidate) *DispatchPlan {
	plan := &DispatchPlan{
		model:     model,
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
	for _, c := range scan.pool {
		if c == winner {
			continue
		}
		// Insertion position among the retained entries (ascending cost).
		pos := len(plan.entries)
		for pos > 0 && c.costMs < plan.entries[pos-1].view.CostMs {
			pos--
		}
		if pos == dispatchPlanMaxAlternates {
			continue // costlier than every retained entry, list full
		}
		if len(plan.entries) < dispatchPlanMaxAlternates {
			plan.entries = append(plan.entries, planEntry{})
		}
		copy(plan.entries[pos+1:], plan.entries[pos:])
		plan.entries[pos] = planEntry{
			provider: c.provider,
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
// rationale on reserveProvider's pending-debit path in scheduler.go.
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
	if pr == nil || pr.RequestID == "" || plan == nil || plan.model == "" {
		return nil, RoutingDecision{}, []PlanSkip{{Reason: PlanSkipExhausted}}
	}
	model := plan.model
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
		// One clock read per revalidated entry (snapshot, cost, admit, claim).
		now := time.Now()
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

		// Snapshot, cost, admit and reservation under ONE p.mu hold — the same
		// commit sequence as commitProviderReservation, so nothing can change
		// the provider between the admit re-check and the debit.
		p.mu.Lock()
		var snap routingSnapshot
		if ok, _ := r.snapshotProviderIntoPLockedEx(&snap, p, model, pr.Traits, relaxTrust, false, now); !ok {
			p.mu.Unlock()
			skip(PlanSkipGateRejected)
			return nil, RoutingDecision{}, false
		}
		candidate, _, ok := r.buildCandidateWithReason(snap, pr, now)
		if !ok {
			p.mu.Unlock()
			skip(PlanSkipGateRejected)
			return nil, RoutingDecision{}, false
		}
		if enforceTTFT && snap.hasBackendCapacity && candidate.breakdown.TTFTMs > pr.MaxTTFTMs {
			p.mu.Unlock()
			skip(PlanSkipGateRejected)
			return nil, RoutingDecision{}, false
		}
		if !r.providerCanAdmitLockedEx(p, model, pr.Traits, relaxTrust, false, now) ||
			(pr.RequiresVision && !r.providerServesVisionModelLocked(p, model, relaxTrust)) {
			p.mu.Unlock()
			skip(PlanSkipGateRejected)
			return nil, RoutingDecision{}, false
		}
		// Half-open capacity probe: check-and-claim under gate.mu, identical to
		// the primary reservation path (p.mu → gate.mu).
		if !r.tryClaimCapacityProbe(p, model, now) {
			p.mu.Unlock()
			skip(PlanSkipGateRejected)
			return nil, RoutingDecision{}, false
		}
		pr.ProviderID = p.ID
		p.addPendingLocked(pr)
		if p.Status != StatusUntrusted && p.Status != StatusOffline {
			p.Status = StatusServing
		}
		p.mu.Unlock()

		if !slotStateModelLoaded(candidate.snapshot.slotState) {
			r.RecordWarmPoolColdDispatch(model)
		}
		// Same calibrator-join rule as the primary path: warm text dispatches
		// only (see reserveProvider).
		bd := candidate.breakdown
		if !pr.RequiresVision && bd.RawTTFTMs > 0 && bd.StateMs == 0 {
			ttftCalibration.notePrediction(pr.RequestID, pr.Attempt, model, candidate.snapshot.chipFamily, bd.RawTTFTMs)
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
			StaticTPS:          candidate.snapshot.decodeTPS,
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

// resortTailLocked re-ranks the unconsumed entries after a quote outcome:
// tier first, ascending scan-time cost within the tier. Cost must be an
// explicit secondary key (not left to sort stability): entries change tier in
// quote-arrival order, so by the time a cheap entry is confirmed a costlier
// one may already sit in the confirmed tier ahead of it — a stability-only
// sort would freeze that inversion and BestConfirmedBackup would return the
// wrong entry. Entries the cursor already consumed are never moved — they are
// history (attempted set, telemetry), not candidates. Caller holds dp.mu.
func (dp *DispatchPlan) resortTailLocked() {
	tail := dp.entries[dp.cursor:]
	sort.SliceStable(tail, func(i, j int) bool {
		ri, rj := planEntryRank(tail[i].view), planEntryRank(tail[j].view)
		if ri != rj {
			return ri < rj
		}
		return tail[i].view.CostMs < tail[j].view.CostMs
	})
}

// ConfirmEntry records an affirmative capacity_quote on the named unconsumed
// entry: the provider's live TTFT quantiles, token headroom, and confidence
// replace nothing (the scan-time estimates stay for telemetry) but ride
// alongside for hedge timing, and the entry is promoted into the confirmed
// tier. A no-op when the entry was already consumed or is not in the plan —
// a quote that raced the dispatch loop carries no ordering work to do.
func (dp *DispatchPlan) ConfirmEntry(providerID string, quote *protocol.CapacityQuoteMessage) {
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

// BestConfirmedBackup returns the lowest-scan-cost unconsumed entry whose
// quote confirmed admissibility, plus its quoted TTFT p90 — the hedge
// scheduler's backup_ttft_q90 input (hedge_schedule.go). ok=false when no
// confirmed entry remains; callers then fall back to the coordinator floor.
// The tail is tier-sorted with cost order preserved inside the confirmed
// tier, so the first confirmed entry IS the lowest-cost one.
func (dp *DispatchPlan) BestConfirmedBackup() (providerID string, ttftP90 time.Duration, ok bool) {
	if dp == nil {
		return "", 0, false
	}
	dp.mu.Lock()
	defer dp.mu.Unlock()
	for i := dp.cursor; i < len(dp.entries); i++ {
		if v := dp.entries[i].view; v.Confirmed {
			return v.ProviderID, v.QuoteTTFTP90, true
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
