package dispatchplan

import (
	"sync"
)

// Plan is the request-local shortlist produced by
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
type Plan[C comparable] struct {
	mu      sync.Mutex
	model   string
	entries []Retained[C]
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

// Model returns the model the plan was built for.
func (dp *Plan[C]) Model() string {
	if dp == nil {
		return ""
	}
	return dp.model
}

// Len returns the number of retained alternates (consumed or not).
func (dp *Plan[C]) Len() int {
	if dp == nil {
		return 0
	}
	return len(dp.entries)
}

// Remaining returns how many alternates the cursor has not yet visited.
func (dp *Plan[C]) Remaining() int {
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
func (dp *Plan[C]) PeekNext() (Entry, bool) {
	if dp == nil {
		return Entry{}, false
	}
	dp.mu.Lock()
	defer dp.mu.Unlock()
	if dp.cursor >= len(dp.entries) {
		return Entry{}, false
	}
	return dp.entries[dp.cursor].View, true
}

// EligibleCount is the number of providers that cleared every structural,
// trait, and trust gate for this request at scan time (including those then
// rejected for capacity or the TTFT ceiling).
func (dp *Plan[C]) EligibleCount() int {
	if dp == nil {
		return 0
	}
	return dp.eligible
}

// AdmissibleCount is the subset of EligibleCount that also passed live
// capacity admission at scan time.
func (dp *Plan[C]) AdmissibleCount() int {
	if dp == nil {
		return 0
	}
	return dp.admissible
}

// DeadlineFeasibleCount is the subset of AdmissibleCount whose estimated TTFT
// also fit the per-request ceiling — the pool the selector actually ranked.
func (dp *Plan[C]) DeadlineFeasibleCount() int {
	if dp == nil {
		return 0
	}
	return dp.deadlineFeasible
}

// RefreshUsed reports whether the plan's single full re-scan refresh has been
// consumed (a refreshed plan is born with it consumed).
func (dp *Plan[C]) RefreshUsed() bool {
	if dp == nil {
		return true
	}
	dp.mu.Lock()
	defer dp.mu.Unlock()
	return dp.refreshUsed
}

// AttemptedProviderIDs returns a copy of every provider ID this plan has bound
// or visited, for callers composing exclusion sets across attempts.
func (dp *Plan[C]) AttemptedProviderIDs() []string {
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
