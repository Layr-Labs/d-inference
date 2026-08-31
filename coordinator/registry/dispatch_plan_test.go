package registry

import (
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// planTestProvider registers a token-budget provider whose routing cost is
// dominated by its ActiveTokenBudgetUsed backlog (observed 80 tok/s →
// 12.5 ms/token), so `used` steps of 400 tokens produce 5,000 ms cost gaps —
// wider than nearTieCostWindowMs (3,000 ms) — making winner and plan order
// fully deterministic under map iteration randomness.
func planTestProvider(t *testing.T, reg *Registry, id, model string, usedTokens int64) *Provider {
	t.Helper()
	return makeTokenBudgetProvider(t, reg, id, model, 100, usedTokens, 1_000_000, 80)
}

func planTestRequest(id string, prompt, maxTok int) *PendingRequest {
	return &PendingRequest{
		RequestID:             id,
		EstimatedPromptTokens: prompt,
		RequestedMaxTokens:    maxTok,
	}
}

func TestDispatchPlanRetainsBoundedLowestCostAlternates(t *testing.T) {
	reg := New(testLogger())
	model := "plan-bounded-model"
	for i := range 12 {
		planTestProvider(t, reg, fmt.Sprintf("p%02d", i), model, int64(i)*400)
	}

	pr := planTestRequest("plan-bounded", 500, 256)
	pr.Model = model
	p, _, plan := reg.ReserveProviderWithPlan(model, pr)
	if p == nil || p.ID != "p00" {
		t.Fatalf("winner=%v, want p00 (lowest backlog)", p)
	}
	if plan == nil {
		t.Fatal("plan is nil on successful reservation")
	}
	if plan.Len() != dispatchPlanMaxAlternates {
		t.Fatalf("plan.Len()=%d, want %d (bounded)", plan.Len(), dispatchPlanMaxAlternates)
	}
	for i, e := range plan.entries {
		want := fmt.Sprintf("p%02d", i+1) // winner p00 excluded, ascending cost
		if e.view.ProviderID != want {
			t.Fatalf("entry[%d]=%q, want %q (ascending cost, winner excluded)", i, e.view.ProviderID, want)
		}
		if e.view.ProviderID == p.ID {
			t.Fatalf("winner %q retained as alternate", p.ID)
		}
	}
	if plan.EligibleCount() != 12 || plan.AdmissibleCount() != 12 || plan.DeadlineFeasibleCount() != 12 {
		t.Fatalf("counts=%d/%d/%d, want 12/12/12",
			plan.EligibleCount(), plan.AdmissibleCount(), plan.DeadlineFeasibleCount())
	}
	if next, ok := plan.PeekNext(); !ok || next.ProviderID != "p01" {
		t.Fatalf("PeekNext=%+v ok=%v, want p01", next, ok)
	}
}

func TestDispatchPlanSmallPoolRetainsAllNonWinners(t *testing.T) {
	reg := New(testLogger())
	model := "plan-small-model"
	for i := range 3 {
		planTestProvider(t, reg, fmt.Sprintf("s%d", i), model, int64(i)*400)
	}

	pr := planTestRequest("plan-small", 500, 256)
	p, _, plan := reg.ReserveProviderWithPlan(model, pr)
	if p == nil || plan == nil {
		t.Fatalf("reservation failed: p=%v plan=%v", p, plan)
	}
	if plan.Len() != 2 {
		t.Fatalf("plan.Len()=%d, want 2 (pool of 3 minus winner)", plan.Len())
	}
}

func TestDispatchPlanAggregateCountsDescribeFullPool(t *testing.T) {
	reg := New(testLogger())
	model := "plan-counts-model"
	for i := range 3 {
		planTestProvider(t, reg, fmt.Sprintf("ok%d", i), model, int64(i)*400)
	}
	// Capacity-rejected: budget entirely consumed (eligible, not admissible).
	makeTokenBudgetProvider(t, reg, "full", model, 100, 100_000, 100_000, 80)
	// TTFT-rejected: decode 1 tok/s → prefill fallback 12 tok/s → ~42 s
	// estimated TTFT, far over the 5 s ceiling (admissible, not feasible).
	makeTokenBudgetProvider(t, reg, "slow", model, 1, 0, 100_000, 1)

	pr := planTestRequest("plan-counts", 500, 256)
	pr.MaxTTFTMs = 5_000
	p, decision, plan := reg.ReserveProviderWithPlan(model, pr)
	if p == nil || plan == nil {
		t.Fatalf("reservation failed: decision=%+v", decision)
	}
	if decision.CandidateCount != 3 || decision.CapacityRejections != 1 || decision.TTFTRejections != 1 {
		t.Fatalf("decision counts=%d/%d/%d, want 3 candidates, 1 capacity, 1 ttft",
			decision.CandidateCount, decision.CapacityRejections, decision.TTFTRejections)
	}
	if plan.EligibleCount() != 5 || plan.AdmissibleCount() != 4 || plan.DeadlineFeasibleCount() != 3 {
		t.Fatalf("counts=%d/%d/%d, want 5/4/3 (eligible ⊇ admissible ⊇ feasible)",
			plan.EligibleCount(), plan.AdmissibleCount(), plan.DeadlineFeasibleCount())
	}
	if plan.Len() != 2 {
		t.Fatalf("plan.Len()=%d, want 2 (only feasible non-winners retained)", plan.Len())
	}
}

// TestReserveProviderWithPlanPrimarySelectionUnchanged pins the plan variant to
// the exact selection ReserveProviderEx makes: same fleet, same request shape →
// same winner and an identical RoutingDecision. Plan retention must be a pure
// byproduct of the existing scan, never a selection fork.
func TestReserveProviderWithPlanPrimarySelectionUnchanged(t *testing.T) {
	model := "plan-equivalence-model"
	build := func() *Registry {
		reg := New(testLogger())
		for i := range 6 {
			planTestProvider(t, reg, fmt.Sprintf("e%d", i), model, int64(i)*400)
		}
		return reg
	}

	prA := planTestRequest("equiv", 500, 256)
	pA, decA := build().ReserveProviderEx(model, prA)

	prB := planTestRequest("equiv", 500, 256)
	pB, decB, plan := build().ReserveProviderWithPlan(model, prB)

	if pA == nil || pB == nil || pA.ID != pB.ID {
		t.Fatalf("winners differ: ReserveProviderEx=%v ReserveProviderWithPlan=%v", pA, pB)
	}
	if decA != decB {
		t.Fatalf("decisions differ:\n ex:   %+v\n plan: %+v", decA, decB)
	}
	if plan == nil || plan.Len() != 5 {
		t.Fatalf("plan=%v, want 5 alternates", plan)
	}
}

func TestReserveNextFromPlanReconnectInvalidatesRetainedIdentity(t *testing.T) {
	reg := New(testLogger())
	model := "plan-reconnect-model"
	planTestProvider(t, reg, "w", model, 0)
	planTestProvider(t, reg, "a1", model, 400)
	a2 := planTestProvider(t, reg, "a2", model, 800)

	pr := planTestRequest("reconnect", 500, 256)
	p, _, plan := reg.ReserveProviderWithPlan(model, pr)
	if p == nil || p.ID != "w" || plan.Len() != 2 {
		t.Fatalf("setup failed: winner=%v plan.Len()=%d", p, plan.Len())
	}

	// a1's session drops and a new session registers under the same ID: the
	// registry maps "a1" to a DIFFERENT *Provider, so the retained identity is
	// dead even though the ID is live again.
	reg.Disconnect("a1")
	planTestProvider(t, reg, "a1", model, 400)

	next, _, skips := reg.ReserveNextFromPlan(planTestRequest("reconnect-retry", 500, 256), plan)
	if next == nil || next != a2 {
		t.Fatalf("next=%v, want the retained a2 pointer", next)
	}
	if len(skips) != 1 || skips[0] != (PlanSkip{ProviderID: "a1", Reason: PlanSkipStaleSession}) {
		t.Fatalf("skips=%+v, want single a1 stale_session", skips)
	}
}

func TestReserveNextFromPlanSkipsGateRejectedEntry(t *testing.T) {
	reg := New(testLogger())
	model := "plan-gate-model"
	planTestProvider(t, reg, "w", model, 0)
	a1 := planTestProvider(t, reg, "a1", model, 400)
	planTestProvider(t, reg, "a2", model, 800)

	pr := planTestRequest("gate", 500, 256)
	if p, _, plan := reg.ReserveProviderWithPlan(model, pr); p == nil || plan == nil {
		t.Fatal("setup reservation failed")
	} else {
		// a1's budget fills between plan build and consumption: revalidation
		// against CURRENT state (freeMemoryAdmits via buildCandidateWithReason)
		// must skip it without any dispatch.
		a1.mu.Lock()
		a1.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 1_000_000
		a1.mu.Unlock()

		next, _, skips := reg.ReserveNextFromPlan(planTestRequest("gate-retry", 500, 256), plan)
		if next == nil || next.ID != "a2" {
			t.Fatalf("next=%v, want a2", next)
		}
		if len(skips) != 1 || skips[0] != (PlanSkip{ProviderID: "a1", Reason: PlanSkipGateRejected}) {
			t.Fatalf("skips=%+v, want single a1 gate_rejected", skips)
		}
	}
}

func TestReserveNextFromPlanHonorsExclusions(t *testing.T) {
	reg := New(testLogger())
	model := "plan-exclude-model"
	planTestProvider(t, reg, "w", model, 0)
	planTestProvider(t, reg, "a1", model, 400)
	planTestProvider(t, reg, "a2", model, 800)

	pr := planTestRequest("exclude", 500, 256)
	_, _, plan := reg.ReserveProviderWithPlan(model, pr)
	if plan == nil {
		t.Fatal("setup reservation failed")
	}

	next, _, skips := reg.ReserveNextFromPlan(planTestRequest("exclude-retry", 500, 256), plan, "a1")
	if next == nil || next.ID != "a2" {
		t.Fatalf("next=%v, want a2 (a1 excluded)", next)
	}
	if len(skips) != 1 || skips[0] != (PlanSkip{ProviderID: "a1", Reason: PlanSkipExcluded}) {
		t.Fatalf("skips=%+v, want single a1 excluded", skips)
	}
}

func TestReserveNextFromPlanExhausted(t *testing.T) {
	reg := New(testLogger())
	model := "plan-exhausted-model"
	planTestProvider(t, reg, "w", model, 0)
	planTestProvider(t, reg, "a1", model, 400)

	pr := planTestRequest("exhaust", 500, 256)
	_, _, plan := reg.ReserveProviderWithPlan(model, pr)
	if next, _, _ := reg.ReserveNextFromPlan(planTestRequest("exhaust-1", 500, 256), plan); next == nil || next.ID != "a1" {
		t.Fatalf("first consumption=%v, want a1", next)
	}

	next, _, skips := reg.ReserveNextFromPlan(planTestRequest("exhaust-2", 500, 256), plan)
	if next != nil {
		t.Fatalf("next=%v, want nil on exhausted plan", next)
	}
	if len(skips) != 1 || skips[0].Reason != PlanSkipExhausted {
		t.Fatalf("skips=%+v, want terminal exhausted", skips)
	}
}

func TestRefreshDispatchPlanExcludesAttemptedAndRunsOnce(t *testing.T) {
	reg := New(testLogger())
	model := "plan-refresh-model"
	planTestProvider(t, reg, "w", model, 0)
	planTestProvider(t, reg, "a1", model, 400)
	planTestProvider(t, reg, "a2", model, 800)
	planTestProvider(t, reg, "a3", model, 1200)

	p, _, plan := reg.ReserveProviderWithPlan(model, planTestRequest("refresh", 500, 256))
	if p == nil || p.ID != "w" || plan.Len() != 3 {
		t.Fatalf("setup failed: winner=%v plan.Len()=%d", p, plan.Len())
	}
	if next, _, _ := reg.ReserveNextFromPlan(planTestRequest("refresh-1", 500, 256), plan); next == nil || next.ID != "a1" {
		t.Fatalf("plan consumption=%v, want a1", next)
	}

	// Refresh re-scans excluding every attempted provider (w, a1): the fresh
	// winner must be a2 and the fresh plan holds only a3, with the single
	// refresh consumed on both plans.
	fp, _, fresh, performed := reg.RefreshDispatchPlan(planTestRequest("refresh-2", 500, 256), plan)
	if !performed {
		t.Fatal("refresh not performed")
	}
	if fp == nil || fp.ID != "a2" {
		t.Fatalf("refresh winner=%v, want a2 (w and a1 attempted)", fp)
	}
	if fresh == nil || fresh.Len() != 1 || fresh.entries[0].view.ProviderID != "a3" {
		t.Fatalf("fresh plan=%+v, want single a3 alternate", fresh)
	}
	if !plan.RefreshUsed() || !fresh.RefreshUsed() {
		t.Fatal("refresh flag not consumed on both plans")
	}
	if _, _, _, again := reg.RefreshDispatchPlan(planTestRequest("refresh-3", 500, 256), plan); again {
		t.Fatal("second refresh of the original plan performed")
	}
	if _, _, _, again := reg.RefreshDispatchPlan(planTestRequest("refresh-4", 500, 256), fresh); again {
		t.Fatal("refresh of the refreshed plan performed")
	}
}

// TestConcurrentPlanReservationsCannotExceedAdmission: two requests hold plans
// naming the same alternate whose reported budget fits exactly one of them.
// Concurrent ReserveNextFromPlan calls serialize under the r.mu write lock and
// each re-runs freeMemoryAdmits against the live pending set, so exactly one
// may land — the plan path cannot over-admit past the provider's budget.
func TestConcurrentPlanReservationsCannotExceedAdmission(t *testing.T) {
	reg := New(testLogger())
	model := "plan-concurrent-model"
	// Cheap primary with ample budget; alternate pB fits ONE 2,500-token
	// request (560 used + 2×2,500 > 4,000). pB's 7,000 ms backlog keeps pA the
	// deterministic primary even with one pending (3,750 ms, outside the
	// 3,000 ms near-tie window).
	pA := planTestProvider(t, reg, "pA", model, 0)
	makeTokenBudgetProvider(t, reg, "pB", model, 100, 560, 4_000, 80)

	pr1 := planTestRequest("c1", 1_000, 1_500)
	p1, _, plan1 := reg.ReserveProviderWithPlan(model, pr1)
	pr2 := planTestRequest("c2", 1_000, 1_500)
	p2, _, plan2 := reg.ReserveProviderWithPlan(model, pr2)
	if p1 == nil || p2 == nil || p1.ID != "pA" || p2.ID != "pA" {
		t.Fatalf("primaries=%v/%v, want pA/pA", p1, p2)
	}
	if plan1.Len() != 1 || plan2.Len() != 1 {
		t.Fatalf("plan lengths=%d/%d, want 1/1 (pB only)", plan1.Len(), plan2.Len())
	}
	// Primary failed for both requests: release pA and fail over to the plans.
	pA.RemovePending("c1")
	pA.RemovePending("c2")

	type result struct {
		p     *Provider
		skips []PlanSkip
	}
	results := make([]result, 2)
	var wg sync.WaitGroup
	for i, plan := range []*DispatchPlan{plan1, plan2} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			pr := planTestRequest(fmt.Sprintf("c%d-retry", i+1), 1_000, 1_500)
			p, _, skips := reg.ReserveNextFromPlan(pr, plan, "pA")
			results[i] = result{p: p, skips: skips}
		}()
	}
	wg.Wait()

	wins := 0
	for _, res := range results {
		if res.p != nil {
			if res.p.ID != "pB" {
				t.Fatalf("winner=%v, want pB", res.p)
			}
			wins++
			continue
		}
		if len(res.skips) != 2 || res.skips[0].Reason != PlanSkipGateRejected ||
			res.skips[1].Reason != PlanSkipExhausted {
			t.Fatalf("loser skips=%+v, want gate_rejected then exhausted", res.skips)
		}
	}
	if wins != 1 {
		t.Fatalf("wins=%d, want exactly 1 (budget fits one request)", wins)
	}
}

// TestConcurrentReservationsCannotDoubleSpendReportedBudget pins the existing
// in-flight ledger end-to-end: reservations serialize under the r.mu write
// lock and addPendingLocked's entry is charged by the very next admission read
// (fillSnapshotPendingAndPool → freeMemoryAdmits' coordinatorExtra), so two
// concurrent requests can never both spend the same reported
// active_token_budget headroom in the heartbeat gap.
func TestConcurrentReservationsCannotDoubleSpendReportedBudget(t *testing.T) {
	reg := New(testLogger())
	model := "ledger-concurrent-model"
	// Budget 3,900; requests of 2,500 and 1,500 tokens sum to 4,000 — whichever
	// serializes first fits, the other must see its debit and be rejected.
	makeTokenBudgetProvider(t, reg, "ledger", model, 100, 0, 3_900, 80)

	shapes := []struct{ prompt, maxTok int }{{1_000, 1_500}, {500, 1_000}}
	selected := make([]*Provider, 2)
	var wg sync.WaitGroup
	for i, shape := range shapes {
		wg.Add(1)
		go func() {
			defer wg.Done()
			pr := planTestRequest(fmt.Sprintf("ledger-%d", i), shape.prompt, shape.maxTok)
			selected[i], _ = reg.ReserveProviderEx(model, pr)
		}()
	}
	wg.Wait()

	wins := 0
	for _, p := range selected {
		if p != nil {
			wins++
		}
	}
	if wins != 1 {
		t.Fatalf("wins=%d, want exactly 1 of two concurrent reservations against one budget", wins)
	}
}

// TestConcurrentPrimaryScansRerankUntilUntriedCapacity proves a scan cohort
// cannot herd onto the same stale cheapest provider or stop after a fixed retry
// count. Three requests first select p00 from the same empty snapshot; commits
// must then observe prior debits and spread across p00, p01, and p02.
func TestConcurrentPrimaryScansRerankUntilUntriedCapacity(t *testing.T) {
	reg := New(testLogger())
	model := "primary-rerank-model"
	for i := range 3 {
		p := planTestProvider(t, reg, fmt.Sprintf("p%02d", i), model, int64(i)*400)
		p.mu.Lock()
		p.BackendCapacity.Slots[0].MaxConcurrency = 1
		p.mu.Unlock()
	}

	arrived := make(chan struct{}, 3)
	release := make(chan struct{})
	var initialScans atomic.Int32
	reg.reservationAfterScan = func(string) {
		if initialScans.Add(1) > 3 {
			return
		}
		arrived <- struct{}{}
		<-release
	}

	selected := make([]*Provider, 3)
	var wg sync.WaitGroup
	for i := range selected {
		wg.Add(1)
		go func() {
			defer wg.Done()
			selected[i], _, _ = reg.ReserveProviderWithPlan(
				model, planTestRequest(fmt.Sprintf("primary-rerank-%d", i), 100, 100))
		}()
	}
	for range 3 {
		select {
		case <-arrived:
		case <-time.After(2 * time.Second):
			close(release)
			t.Fatal("primary scans serialized instead of reaching the shared-scan barrier")
		}
	}
	close(release)
	wg.Wait()

	winners := make(map[string]bool, 3)
	for i, p := range selected {
		if p == nil {
			t.Fatalf("request %d returned nil while an untried provider remained", i)
		}
		winners[p.ID] = true
	}
	if len(winners) != 3 {
		t.Fatalf("winner set=%v, want one request on each of p00, p01, and p02", winners)
	}
	for i, p := range selected {
		p.RemovePending(fmt.Sprintf("primary-rerank-%d", i))
	}
}

// TestCommitCapacityRejectionSurvivesCandidateExclusion proves a provider that
// becomes full between scan and commit remains classified as transient capacity
// after it is excluded from the next scan.
func TestCommitCapacityRejectionSurvivesCandidateExclusion(t *testing.T) {
	reg := New(testLogger())
	model := "commit-rejection-counters"
	p := planTestProvider(t, reg, "only", model, 0)
	scanned := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	reg.reservationAfterScan = func(string) {
		once.Do(func() {
			close(scanned)
			<-release
		})
	}
	type result struct {
		provider *Provider
		decision RoutingDecision
	}
	resultCh := make(chan result, 1)
	go func() {
		provider, decision := reg.ReserveProviderEx(
			model, planTestRequest("commit-capacity-reject", 100, 100))
		resultCh <- result{provider: provider, decision: decision}
	}()
	<-scanned
	p.mu.Lock()
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 100
	p.mu.Unlock()
	close(release)

	got := <-resultCh
	if got.provider != nil {
		t.Fatalf("provider=%q, want nil after commit-time capacity loss", got.provider.ID)
	}
	if got.decision.CapacityRejections != 1 {
		t.Fatalf("CapacityRejections=%d, want 1 preserved across exclusion", got.decision.CapacityRejections)
	}
}

// TestCommitRejectsExpiredFirstContentDeadline proves scan and write-lock wait
// time cannot produce a doomed pending debit after the absolute clock expires.
func TestCommitRejectsExpiredFirstContentDeadline(t *testing.T) {
	reg := New(testLogger())
	model := "commit-deadline"
	p := planTestProvider(t, reg, "deadline-provider", model, 0)
	pr := planTestRequest("commit-deadline-request", 100, 100)
	pr.FirstContentDeadline = time.Now().Add(time.Minute)

	scanned := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	reg.reservationAfterScan = func(string) {
		once.Do(func() {
			close(scanned)
			<-release
		})
	}
	selected := make(chan *Provider, 1)
	go func() {
		provider, _, _ := reg.ReserveProviderWithPlan(model, pr)
		selected <- provider
	}()
	<-scanned
	pr.FirstContentDeadline = time.Now().Add(-time.Second)
	close(release)

	if provider := <-selected; provider != nil {
		t.Fatalf("provider=%q, want nil after deadline expired before commit", provider.ID)
	}
	if pending := p.PendingCount(); pending != 0 {
		t.Fatalf("pending=%d, want no debit for expired request", pending)
	}
}

// TestHeartbeatResyncRestoresProviderReportedTruth: while a reservation is in
// the heartbeat dark window, its coordinator-side debit gates admission; once
// the provider's heartbeat reports the admitted work, committedTokenBudget
// covers the pending entry and coordinatorExtra drops to zero — the same
// in-flight tokens are charged exactly once, per the provider's own report.
func TestHeartbeatResyncRestoresProviderReportedTruth(t *testing.T) {
	reg := New(testLogger())
	model := "ledger-resync-model"
	p := makeTokenBudgetProvider(t, reg, "resync", model, 100, 0, 3_900, 80)

	// Dark window: A (2,500 tokens) reserves; its pending debit must reject
	// B (1,500 tokens: 2,500 + 1,500 > 3,900) even though the heartbeat still
	// reports zero budget used.
	if sel, _ := reg.ReserveProviderEx(model, planTestRequest("resync-a", 1_000, 1_500)); sel == nil {
		t.Fatal("request A did not reserve")
	}
	if sel, decision := reg.ReserveProviderEx(model, planTestRequest("resync-b", 500, 1_000)); sel != nil {
		t.Fatalf("request B reserved past the pending debit: %+v", decision)
	} else if decision.CapacityRejections != 1 {
		t.Fatalf("decision=%+v, want 1 capacity rejection", decision)
	}

	// Heartbeat re-sync: the provider now reports A's 2,500 tokens as active.
	// A is STILL coordinator-pending, but committedTokenBudget covers it, so a
	// 1,400-token request fits the remaining 3,900-2,500 exactly — the debit
	// is not double-counted on top of the provider's report.
	p.mu.Lock()
	p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 2_500
	p.mu.Unlock()
	if sel, decision := reg.ReserveProviderEx(model, planTestRequest("resync-c", 400, 1_000)); sel == nil {
		t.Fatalf("request C rejected after heartbeat re-sync: %+v", decision)
	}
}

// TestReserveNextFromPlanVersionDiverseRetry pins the soft two-pass
// AvoidVersion rule on plan consumption (codex P1: a retry populated
// pr.Traits.AvoidVersion, but revalidation walked the plan in raw cost order
// and re-dispatched onto the failed build even when a diverse entry
// remained). Versions are set AFTER the plan is built: the pass must read the
// provider's LIVE reported version, never a scan-time copy.
func TestReserveNextFromPlanVersionDiverseRetry(t *testing.T) {
	reg := New(testLogger())
	model := "plan-avoid-version-model"
	planTestProvider(t, reg, "w", model, 0)
	planTestProvider(t, reg, "a1", model, 400)
	planTestProvider(t, reg, "a2", model, 800)

	pr := planTestRequest("avoid-primary", 500, 256)
	pr.Model = model
	if p, _, plan := reg.ReserveProviderWithPlan(model, pr); p == nil || p.ID != "w" || plan == nil {
		t.Fatalf("primary=%v, want w with a plan", p)
	} else {
		// Live versions diverge after the scan: the cheaper alternate a1 runs
		// the version the retry must avoid; a2 runs a different build.
		setProviderVersion(reg.GetProvider("a1"), "0.6.4")
		setProviderVersion(reg.GetProvider("a2"), "0.6.5")

		retry := planTestRequest("avoid-retry", 500, 256)
		retry.Traits.AvoidVersion = "0.6.4"
		next, _, skips := reg.ReserveNextFromPlan(retry, plan)
		if next == nil || next.ID != "a2" {
			t.Fatalf("next=%v, want a2 (the diverse version)", next)
		}
		if len(skips) != 1 || skips[0] != (PlanSkip{ProviderID: "a1", Reason: PlanSkipVersionAvoided}) {
			t.Fatalf("skips=%+v, want single a1 version_avoided", skips)
		}
	}
}

// When every remaining entry runs the avoided version, diversity must fall
// back to the same-version pool (cost order) rather than failing closed —
// parity with scanCandidatesLocked's soft narrowing.
func TestReserveNextFromPlanAvoidVersionNeverFailsClosed(t *testing.T) {
	reg := New(testLogger())
	model := "plan-avoid-all-model"
	planTestProvider(t, reg, "w", model, 0)
	planTestProvider(t, reg, "a1", model, 400)
	planTestProvider(t, reg, "a2", model, 800)

	pr := planTestRequest("avoid-all-primary", 500, 256)
	pr.Model = model
	_, _, plan := reg.ReserveProviderWithPlan(model, pr)
	if plan == nil {
		t.Fatal("plan is nil")
	}
	setProviderVersion(reg.GetProvider("a1"), "0.6.4")
	setProviderVersion(reg.GetProvider("a2"), "0.6.4")

	retry := planTestRequest("avoid-all-retry", 500, 256)
	retry.Traits.AvoidVersion = "0.6.4"
	next, _, skips := reg.ReserveNextFromPlan(retry, plan)
	if next == nil || next.ID != "a1" {
		t.Fatalf("next=%v, want a1 (cost-order fallback onto the avoided version)", next)
	}
	if len(skips) != 0 {
		t.Fatalf("skips=%+v, want none (fallback entries reserve with their own outcome)", skips)
	}
}

// An empty AvoidVersion must leave plan consumption byte-identical to the
// single-pass behavior: pure cost order, no deferral, no version skips.
func TestReserveNextFromPlanNoAvoidVersionUnchanged(t *testing.T) {
	reg := New(testLogger())
	model := "plan-no-avoid-model"
	planTestProvider(t, reg, "w", model, 0)
	planTestProvider(t, reg, "a1", model, 400)
	planTestProvider(t, reg, "a2", model, 800)

	pr := planTestRequest("no-avoid-primary", 500, 256)
	pr.Model = model
	_, _, plan := reg.ReserveProviderWithPlan(model, pr)
	if plan == nil {
		t.Fatal("plan is nil")
	}
	setProviderVersion(reg.GetProvider("a1"), "0.6.4")
	setProviderVersion(reg.GetProvider("a2"), "0.6.5")

	retry := planTestRequest("no-avoid-retry", 500, 256)
	next, _, skips := reg.ReserveNextFromPlan(retry, plan)
	if next == nil || next.ID != "a1" {
		t.Fatalf("next=%v, want a1 (plain cost order)", next)
	}
	if len(skips) != 0 {
		t.Fatalf("skips=%+v, want none", skips)
	}
}
