package registry

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestFirstContentPlanQuoteTimingUsesPreferredBackup(t *testing.T) {
	r := New(testLogger())
	if err := r.ConfigureFirstContentRouting(FirstContentRoutingPrefer); err != nil {
		t.Fatal(err)
	}
	const model = "first-content-plan-quote-timing"
	cheap := planTestProvider(t, r, "cheap-fallback", model, 0)
	fast := planTestProvider(t, r, "feasible-backup", model, 0)
	setFirstContentPlanMeasurements(cheap, 400)
	setFirstContentPlanMeasurements(fast, 4_000)
	pool := []*routingCandidate{
		{provider: cheap, costMs: 1, firstContent: FirstContentEstimate{Status: "infeasible"}},
		{provider: fast, costMs: 2, firstContent: FirstContentEstimate{Status: "feasible"}},
	}
	plan := newDispatchPlan(model, candidateScan{pool: pool, planPool: pool, ordinaryPlanPool: pool}, nil)
	plan.ConfirmEntry(fast.ID, &protocol.CapacityQuoteMessage{AdmissibleNow: true, TTFTP90MS: 9_500})
	plan.ConfirmEntry(cheap.ID, &protocol.CapacityQuoteMessage{AdmissibleNow: true, TTFTP90MS: 2_000})
	id, q90, ok := plan.BestConfirmedBackup()
	if !ok || id != fast.ID || q90 != 9500*time.Millisecond {
		t.Fatalf("timing picked %q q90=%v ok=%v, want feasible backup's 9.5s", id, q90, ok)
	}
	got, _, _ := r.ReserveNextFromPlan(firstContentPlanRequest("backup", model), plan)
	if got == nil || got.ID != id {
		t.Fatalf("timed backup %q differs from dispatched backup %v", id, got)
	}
	if id, _, ok := plan.BestConfirmedBackup(); !ok || id != cheap.ID {
		t.Fatalf("remaining fallback quote was lost: id=%q ok=%v", id, ok)
	}
}

func TestFirstContentPlanDoesNotTimeFallbackWhenPreferredBackupUnconfirmed(t *testing.T) {
	pool := []*routingCandidate{
		{provider: &Provider{ID: "cheap-fallback"}, costMs: 1, firstContent: FirstContentEstimate{Status: "infeasible"}},
		{provider: &Provider{ID: "feasible-backup"}, costMs: 2, firstContent: FirstContentEstimate{Status: "feasible"}},
	}
	plan := newDispatchPlan("model", candidateScan{pool: pool, planPool: pool, ordinaryPlanPool: pool}, nil)
	plan.ConfirmEntry("cheap-fallback", &protocol.CapacityQuoteMessage{AdmissibleNow: true, TTFTP90MS: 2_000})
	if id, _, ok := plan.BestConfirmedBackup(); ok {
		t.Fatalf("used %q's quote for a different preferred backup", id)
	}
}

func TestFirstContentPlanRollbackRecoversDiscardedOrdinaryCandidates(t *testing.T) {
	for _, mode := range []string{FirstContentRoutingOff, FirstContentRoutingShadow} {
		t.Run(mode, func(t *testing.T) {
			r := New(testLogger())
			if err := r.ConfigureFirstContentRouting(FirstContentRoutingPrefer); err != nil {
				t.Fatal(err)
			}
			const model = "first-content-plan-many-rollback"
			var pool []*routingCandidate
			for i := range 10 {
				provider := planTestProvider(t, r, fmt.Sprintf("cheap-%02d", i), model, 0)
				setFirstContentPlanMeasurements(provider, 400)
				pool = append(pool, &routingCandidate{provider: provider, costMs: float64(i + 1), firstContent: FirstContentEstimate{Status: "infeasible"}})
			}
			for i := range 8 {
				provider := planTestProvider(t, r, fmt.Sprintf("fast-%02d", i), model, 0)
				setFirstContentPlanMeasurements(provider, 4_000)
				pool = append(pool, &routingCandidate{provider: provider, costMs: float64(100 + i), firstContent: FirstContentEstimate{Status: "feasible"}})
			}
			plan := newDispatchPlan(model, candidateScan{pool: pool, planPool: pool, ordinaryPlanPool: pool}, nil)
			if plan.Len() != 8 || len(plan.probeTargets()) != 8 || len(plan.alternateEntries) != 8 {
				t.Fatalf("shortlists are not independently bounded: active=%d probe=%d ordinary=%d", plan.Len(), len(plan.probeTargets()), len(plan.alternateEntries))
			}
			for _, entry := range plan.entries {
				if !entry.firstContentFeasible {
					t.Fatal("fixture did not displace every cheap ordinary candidate")
				}
			}
			first, _, _ := r.ReserveNextFromPlan(firstContentPlanRequest("before-rollback", model), plan)
			if first == nil || first.ID != "fast-00" {
				t.Fatalf("preferred dispatch=%v", first)
			}
			if err := r.ConfigureFirstContentRouting(mode); err != nil {
				t.Fatal(err)
			}
			request := firstContentPlanRequest("after-rollback", model)
			request.FirstContentDeadline = time.Now().Add(2 * time.Second)
			deadline := request.FirstContentDeadline
			got, _, _ := r.ReserveNextFromPlan(request, plan)
			if got == nil || got.ID != "cheap-00" {
				t.Fatalf("rollback could not recover discarded cheap candidate: %v", got)
			}
			if request.FirstContentDeadline != deadline || request.FirstContentBudgetMS > 2_000 {
				t.Fatal("rollback reset the request's remaining clock")
			}
			attempted := plan.AttemptedProviderIDs()
			if len(attempted) != 2 || plan.Remaining() != 7 {
				t.Fatalf("rollback lost attempt history: attempted=%v remaining=%d", attempted, plan.Remaining())
			}
			// A later enable recovers the preferred tail without retrying its
			// already-consumed first provider.
			if err := r.ConfigureFirstContentRouting(FirstContentRoutingPrefer); err != nil {
				t.Fatal(err)
			}
			got, _, _ = r.ReserveNextFromPlan(firstContentPlanRequest("re-enabled", model), plan)
			if got == nil || got.ID != "fast-01" {
				t.Fatalf("re-enable repeated or lost preferred identity: %v", got)
			}
		})
	}
}

func TestFirstContentPlanRollbackPreservesQuotesForOverlap(t *testing.T) {
	pool := []*routingCandidate{
		{provider: &Provider{ID: "cheap"}, costMs: 1, firstContent: FirstContentEstimate{Status: "infeasible"}},
		{provider: &Provider{ID: "fast"}, costMs: 2, firstContent: FirstContentEstimate{Status: "feasible"}},
	}
	plan := newDispatchPlan("model", candidateScan{pool: pool, planPool: pool, ordinaryPlanPool: pool}, nil)
	plan.ConfirmEntry("fast", &protocol.CapacityQuoteMessage{AdmissibleNow: true, TTFTP90MS: 9_500})
	plan.useFirstContentMode(false)
	id, q90, ok := plan.BestConfirmedBackup()
	if !ok || id != "fast" || q90 != 9500*time.Millisecond {
		t.Fatalf("rollback lost overlapping quote: id=%q q90=%v ok=%v", id, q90, ok)
	}
	plan.DemoteEntry("fast")
	plan.useFirstContentMode(true)
	if id, _, ok := plan.BestConfirmedBackup(); ok {
		t.Fatalf("re-enable restored stale confirmation for %q", id)
	}
}

func TestFirstContentPlanQuoteViewObservesRollbackBeforeReservation(t *testing.T) {
	r := New(testLogger())
	if err := r.ConfigureFirstContentRouting(FirstContentRoutingPrefer); err != nil {
		t.Fatal(err)
	}
	pool := []*routingCandidate{
		{provider: &Provider{ID: "cheap"}, costMs: 1, firstContent: FirstContentEstimate{Status: "infeasible"}},
		{provider: &Provider{ID: "fast"}, costMs: 2, firstContent: FirstContentEstimate{Status: "feasible"}},
	}
	plan := newDispatchPlan("model", candidateScan{pool: pool, planPool: pool, ordinaryPlanPool: pool}, nil)
	plan.registry = r
	plan.ConfirmEntry("cheap", &protocol.CapacityQuoteMessage{AdmissibleNow: true, TTFTP90MS: 2_000})
	plan.ConfirmEntry("fast", &protocol.CapacityQuoteMessage{AdmissibleNow: true, TTFTP90MS: 9_500})
	if id, _, _ := plan.BestConfirmedBackup(); id != "fast" {
		t.Fatalf("preferred quote=%q", id)
	}
	if err := r.ConfigureFirstContentRouting(FirstContentRoutingShadow); err != nil {
		t.Fatal(err)
	}
	if id, _, _ := plan.BestConfirmedBackup(); id != "cheap" {
		t.Fatalf("quote view did not observe rollback before reservation: %q", id)
	}
}

func TestFirstContentPlanProbeViewObservesRollbackAndKeepsDormantQuotes(t *testing.T) {
	r := New(testLogger())
	if err := r.ConfigureFirstContentRouting(FirstContentRoutingPrefer); err != nil {
		t.Fatal(err)
	}
	fast := &routingCandidate{provider: &Provider{ID: "fast"}, costMs: 2, firstContent: FirstContentEstimate{Status: "feasible"}}
	cheap := &routingCandidate{provider: &Provider{ID: "cheap"}, costMs: 1, firstContent: FirstContentEstimate{Status: "infeasible"}}
	plan := newDispatchPlan("model", candidateScan{pool: []*routingCandidate{fast}, planPool: []*routingCandidate{fast}, ordinaryPlanPool: []*routingCandidate{cheap}}, nil)
	plan.registry = r
	if err := r.ConfigureFirstContentRouting(FirstContentRoutingOff); err != nil {
		t.Fatal(err)
	}
	targets := plan.probeTargets()
	if len(targets) != 1 || targets[0].view.ProviderID != "cheap" {
		t.Fatalf("probe view did not switch to ordinary shortlist: %+v", targets)
	}
	// The single probe round can settle after a mode transition. Its outcome
	// must remain attached to the inactive identity for a later re-enable.
	plan.ConfirmEntry("fast", &protocol.CapacityQuoteMessage{AdmissibleNow: true, TTFTP90MS: 9_500})
	if err := r.ConfigureFirstContentRouting(FirstContentRoutingPrefer); err != nil {
		t.Fatal(err)
	}
	if id, q90, ok := plan.BestConfirmedBackup(); !ok || id != "fast" || q90 != 9500*time.Millisecond {
		t.Fatalf("lost dormant confirmation: id=%q q90=%v ok=%v", id, q90, ok)
	}
	if err := r.ConfigureFirstContentRouting(FirstContentRoutingOff); err != nil {
		t.Fatal(err)
	}
	plan.probeTargets()
	plan.DemoteEntry("fast")
	if err := r.ConfigureFirstContentRouting(FirstContentRoutingPrefer); err != nil {
		t.Fatal(err)
	}
	if id, _, ok := plan.BestConfirmedBackup(); ok {
		t.Fatalf("resurrected dormant confirmation for %q", id)
	}
}

func TestFirstContentPlanEnabledAfterOrdinaryRetentionDoesNotRetargetHedgeQuote(t *testing.T) {
	r := New(testLogger())
	pool := []*routingCandidate{{provider: &Provider{ID: "ordinary"}, costMs: 1}}
	plan := newDispatchPlan("model", candidateScan{pool: pool}, nil)
	plan.registry = r
	plan.ConfirmEntry("ordinary", &protocol.CapacityQuoteMessage{AdmissibleNow: true, TTFTP90MS: 2_000})
	if _, _, ok := plan.BestConfirmedBackup(); !ok {
		t.Fatal("ordinary quote missing")
	}
	if err := r.ConfigureFirstContentRouting(FirstContentRoutingPrefer); err != nil {
		t.Fatal(err)
	}
	if id, _, ok := plan.BestConfirmedBackup(); ok {
		t.Fatalf("ordinary retention invented preferred hedge %q", id)
	}
	if err := r.ConfigureFirstContentRouting(FirstContentRoutingOff); err != nil {
		t.Fatal(err)
	}
	if id, _, ok := plan.BestConfirmedBackup(); !ok || id != "ordinary" {
		t.Fatalf("rollback lost ordinary quote %q ok=%v", id, ok)
	}
}

func TestFirstContentPlanSoftPreferenceRetentionAndQuoteMatchDispatch(t *testing.T) {
	for _, policy := range []string{"decode_floor", "version"} {
		t.Run(policy, func(t *testing.T) {
			r := New(testLogger())
			if err := r.ConfigureFirstContentRouting(FirstContentRoutingPrefer); err != nil {
				t.Fatal(err)
			}
			const model = "first-content-plan-soft-tier"
			add := func(id string, prefill, decode float64, version string) *Provider {
				provider := planTestProvider(t, r, id, model, 0)
				setFirstContentPlanMeasurements(provider, 8_000)
				provider.mu.Lock()
				provider.PrefillTPS = prefill
				provider.BackendCapacity.Slots[0].ObservedPrefillTPS = prefill
				provider.BackendCapacity.Slots[0].ObservedDecodeTPS = decode
				provider.Version = version
				provider.mu.Unlock()
				return provider
			}
			primary := add("primary", 20_000, 200, "0.9.3")
			preferred := add("preferred-backup", 1_000, 100, "0.9.3")
			for i := range 9 {
				decode := 100.0
				if policy == "decode_floor" {
					decode = 40
				}
				add(fmt.Sprintf("cheap-%02d", i), 5_000, decode, "0.9.2")
			}
			request := firstContentPlanRequest("primary-attempt", model)
			if policy == "decode_floor" {
				request.MinDecodeTPS = 60
			} else {
				request.Traits.AvoidVersion = "0.9.2"
			}
			got, _, plan := r.ReserveProviderWithPlan(model, request)
			if got != primary || plan == nil {
				t.Fatalf("unexpected primary %v", got)
			}
			if next, ok := plan.PeekNext(); !ok || next.ProviderID != preferred.ID {
				t.Fatalf("eight cheap candidates crowded out preferred alternate: next=%+v ok=%v", next, ok)
			}
			plan.ConfirmEntry(preferred.ID, &protocol.CapacityQuoteMessage{AdmissibleNow: true, TTFTP90MS: 9_500})
			plan.ConfirmEntry("cheap-00", &protocol.CapacityQuoteMessage{AdmissibleNow: true, TTFTP90MS: 2_000})
			id, q90, ok := plan.BestConfirmedBackup()
			if !ok || id != preferred.ID || q90 != 9500*time.Millisecond {
				t.Fatalf("wrong %s hedge tier: id=%q q90=%v ok=%v", policy, id, q90, ok)
			}
			retry := firstContentPlanRequest("backup-attempt", model)
			retry.MinDecodeTPS, retry.Traits = request.MinDecodeTPS, request.Traits
			got, _, _ = r.ReserveNextFromPlan(retry, plan)
			if got != preferred {
				t.Fatalf("quote targeted %q but dispatched %v", id, got)
			}
		})
	}
}

func TestFirstContentPlanQuotePolicyRefreshKeepsSoftFallback(t *testing.T) {
	pool := []*routingCandidate{
		{provider: &Provider{ID: "a"}, costMs: 1, firstContent: FirstContentEstimate{Status: "feasible"}, snapshot: routingSnapshot{binaryVersion: "old", observedDecodeTPS: 100}},
		{provider: &Provider{ID: "b"}, costMs: 2, firstContent: FirstContentEstimate{Status: "feasible"}, snapshot: routingSnapshot{binaryVersion: "new", observedDecodeTPS: 100}},
	}
	plan := newDispatchPlan("model", candidateScan{pool: pool, planPool: pool, ordinaryPlanPool: pool}, nil)
	plan.ConfirmEntry("a", &protocol.CapacityQuoteMessage{AdmissibleNow: true, TTFTP90MS: 2_000})
	plan.ConfirmEntry("b", &protocol.CapacityQuoteMessage{AdmissibleNow: true, TTFTP90MS: 9_500})
	plan.updateFirstContentRequest(&PendingRequest{Traits: RequestTraits{AvoidVersion: "old"}})
	if id, _, _ := plan.BestConfirmedBackup(); id != "b" {
		t.Fatalf("retry version update retained old quote %q", id)
	}
	plan.consumeEntry(plan.entries[0])
	if id, _, ok := plan.BestConfirmedBackup(); !ok || id != "a" {
		t.Fatalf("exhausted diverse tier lost soft fallback: id=%q ok=%v", id, ok)
	}
}
