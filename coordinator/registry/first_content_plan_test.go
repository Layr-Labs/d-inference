package registry

import (
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func setFirstContentPlanMeasurements(p *Provider, isolatedTPS float64) {
	p.mu.Lock()
	defer p.mu.Unlock()
	zero, initialized := int64(0), true
	p.LastHeartbeat = time.Now()
	p.capacitySamplesAt = p.LastHeartbeat
	slot := &p.BackendCapacity.Slots[0]
	slot.State = "idle"
	slot.ObservedDecodeTPS = 100
	slot.Telemetry = &protocol.SlotTelemetry{
		QueuedPrefillTokens: &zero, PartialPrefillRows: &zero,
		IsolatedPrefillTPS: &isolatedTPS, EWMAInitialized: &initialized,
	}
}

func firstContentTestPlan(model string, providers ...*Provider) *DispatchPlan {
	plan := &DispatchPlan{model: model, attempted: make(map[string]struct{})}
	for i, provider := range providers {
		plan.entries = append(plan.entries, planEntry{
			provider: provider,
			view:     PlanEntry{ProviderID: provider.ID, CostMs: float64(i + 1)},
		})
	}
	return plan
}

func firstContentPlanRequest(id, model string) *PendingRequest {
	return &PendingRequest{
		RequestID: id, Model: model, EstimatedPromptTokens: 16_000,
		RequestedMaxTokens: 128, FirstContentDeadline: time.Now().Add(12 * time.Second),
	}
}

func TestFirstContentPlanPrefersLiveFeasibleAndPreservesFallback(t *testing.T) {
	forEachCommitMode(t, func(t *testing.T, mode reserveCommitMode) {
		r := New(testLogger())
		setReserveCommitModeForTest(r, mode)
		if err := r.ConfigureFirstContentRouting(FirstContentRoutingPrefer); err != nil {
			t.Fatal(err)
		}
		const model = "first-content-plan"
		slow := planTestProvider(t, r, "cheap-slow", model, 0)
		fast := planTestProvider(t, r, "fast", model, 0)
		setFirstContentPlanMeasurements(slow, 400)
		setFirstContentPlanMeasurements(fast, 4_000)
		plan := firstContentTestPlan(model, slow, fast)
		first := firstContentPlanRequest("first", model)
		got, decision, skips := r.ReserveNextFromPlan(first, plan)
		if got != fast || decision.FirstContent.Status != "feasible" || len(skips) != 0 {
			t.Fatalf("got=%v decision=%+v skips=%+v, want feasible fast", got, decision, skips)
		}
		if plan.Remaining() != 1 || len(plan.AttemptedProviderIDs()) != 1 || plan.AttemptedProviderIDs()[0] != fast.ID {
			t.Fatalf("deferred fallback consumed: remaining=%d attempted=%v", plan.Remaining(), plan.AttemptedProviderIDs())
		}
		second := firstContentPlanRequest("second", model)
		got, decision, _ = r.ReserveNextFromPlan(second, plan)
		if got != slow || decision.FirstContent.Status != "infeasible" || decision.TTFTRejections != 0 {
			t.Fatalf("fallback was turned into rejection: got=%v decision=%+v", got, decision)
		}
	})
}

func TestFirstContentPlanUsesCurrentCacheEvidenceForNewAttempt(t *testing.T) {
	for _, change := range []string{"none", "removed", "reconfigured", "shadow"} {
		t.Run(change, func(t *testing.T) {
			r, _, _ := exactTestRegistry(t)
			removeTestProvider(r, "provider-a")
			if err := r.ConfigureFirstContentRouting(FirstContentRoutingPrefer); err != nil {
				t.Fatal(err)
			}
			capability := indexTestCapability(1)
			holder := checkpointTestProvider(t, r, "holder", capability)
			fallback := planTestProvider(t, r, "fallback", "model", 0)
			setFirstContentPlanMeasurements(holder, 1_000)
			setFirstContentPlanMeasurements(fallback, 200)
			checkpoint, floor := exactTestAnchor(16, "c"), exactTestAnchor(17, "d")
			cachePlan := boundTestCachePlan(r, exactTestPlan(checkpoint, floor))
			_, ready := checkpointTestAttempt(t, r, holder, capability, "donor", cachePlan, 1)
			ready.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint}
			ready.ExpectedPrefillTokensSaved, ready.StageMs = checkpoint.TokenCount, 100
			if !r.ApplyPrefixCacheReadyV2(holder.ID, ready) {
				t.Fatal("cache receipt rejected")
			}
			plan := firstContentTestPlan("model", fallback, holder)
			switch change {
			case "removed":
				r.cacheRouting.disconnect(holder.ID, cacheHolderRemovalDisconnect)
			case "reconfigured":
				if err := r.ConfigureCacheRouting(generationTestConfig(CacheRoutingOn)); err != nil {
					t.Fatal(err)
				}
			case "shadow":
				if err := r.ConfigureFirstContentRouting(FirstContentRoutingShadow); err != nil {
					t.Fatal(err)
				}
				// Force the existing plan to pick the holder, so shadow can
				// measure its cache benefit without publishing a new cost.
				plan = firstContentTestPlan("model", holder)
			}
			request := &PendingRequest{
				RequestID: "new-retry", Model: "model", CachePlan: cachePlan,
				EstimatedPromptTokens: cachePlan.PromptTokenCount, RequestedMaxTokens: 128,
				FirstContentDeadline: time.Now().Add(4 * time.Second),
			}
			if len(request.cacheRoutingHints) != 0 {
				t.Fatal("fixture already has cache hints")
			}
			got, decision, _ := r.ReserveNextFromPlan(request, plan)
			if request.CacheOpportunity.Evaluated {
				t.Fatal("plan lookup published incomplete full-scan cache opportunity counts")
			}
			if change == "removed" || change == "reconfigured" {
				if got != fallback || decision.FirstContent.CachedTokens != 0 {
					t.Fatalf("removed holder retained credit: provider=%v decision=%+v", got, decision)
				}
			} else if got != holder || decision.FirstContent.Status != "feasible" || decision.FirstContent.CachedTokens <= 0 || decision.FirstContent.RestoreMs != 100 {
				t.Fatalf("new attempt missed validated cache evidence: provider=%v decision=%+v", got, decision)
			}
			if change == "shadow" && (decision.CacheDiscountMs != 0 || decision.CacheTier != "" || request.CacheSelectionMode != "" || request.CacheSelectionSelected) {
				t.Fatalf("shadow changed cache decision metadata: decision=%+v request=%+v", decision, request)
			}
		})
	}
}

func TestFirstContentPlanFeasibilityPrecedesSoftVersionPreference(t *testing.T) {
	r := New(testLogger())
	if err := r.ConfigureFirstContentRouting(FirstContentRoutingPrefer); err != nil {
		t.Fatal(err)
	}
	const model = "first-content-plan-version"
	slow := planTestProvider(t, r, "diverse-slow", model, 0)
	fast := planTestProvider(t, r, "avoided-fast", model, 0)
	setFirstContentPlanMeasurements(slow, 400)
	setFirstContentPlanMeasurements(fast, 4_000)
	fast.mu.Lock()
	fast.Version = "0.9.2"
	fast.mu.Unlock()
	request := firstContentPlanRequest("version", model)
	request.Traits.AvoidVersion = "0.9.2"
	got, _, _ := r.ReserveNextFromPlan(request, firstContentTestPlan(model, slow, fast))
	if got != fast {
		t.Fatalf("version preference hid sole feasible provider: %v", got)
	}
}

func TestFirstContentPlanOffAndShadowKeepExistingOrder(t *testing.T) {
	for _, mode := range []string{FirstContentRoutingOff, FirstContentRoutingShadow} {
		t.Run(mode, func(t *testing.T) {
			r := New(testLogger())
			if err := r.ConfigureFirstContentRouting(mode); err != nil {
				t.Fatal(err)
			}
			const model = "first-content-plan-mode"
			slow := planTestProvider(t, r, "cheap-slow", model, 0)
			fast := planTestProvider(t, r, "fast", model, 0)
			setFirstContentPlanMeasurements(slow, 400)
			setFirstContentPlanMeasurements(fast, 4_000)
			got, _, _ := r.ReserveNextFromPlan(firstContentPlanRequest("mode", model), firstContentTestPlan(model, slow, fast))
			if got != slow {
				t.Fatalf("%s changed winner to %v", mode, got)
			}
		})
	}
}

func TestFirstContentPlanReevaluatesRemainingDeadline(t *testing.T) {
	r := New(testLogger())
	if err := r.ConfigureFirstContentRouting(FirstContentRoutingPrefer); err != nil {
		t.Fatal(err)
	}
	const model = "first-content-plan-deadline"
	a := planTestProvider(t, r, "old-feasible", model, 0)
	b := planTestProvider(t, r, "still-feasible", model, 0)
	setFirstContentPlanMeasurements(a, 4_000)
	setFirstContentPlanMeasurements(b, 10_000)
	plan := firstContentTestPlan(model, a, b)
	plan.entries[0].firstContentFeasible, plan.entries[1].firstContentFeasible = true, true
	request := firstContentPlanRequest("short-clock", model)
	request.FirstContentDeadline = time.Now().Add(6 * time.Second)
	got, decision, _ := r.ReserveNextFromPlan(request, plan)
	if got != b || decision.FirstContent.BudgetMs > 6_000 {
		t.Fatalf("stale scan-time feasibility won: provider=%v decision=%+v", got, decision)
	}
}

func TestFirstContentPlanReevaluatesChangedMeasurements(t *testing.T) {
	for _, change := range []string{"rate", "stale", "busy"} {
		t.Run(change, func(t *testing.T) {
			r := New(testLogger())
			if err := r.ConfigureFirstContentRouting(FirstContentRoutingPrefer); err != nil {
				t.Fatal(err)
			}
			const model = "first-content-plan-changing"
			a := planTestProvider(t, r, "stale-winner", model, 0)
			b := planTestProvider(t, r, "current-feasible", model, 0)
			setFirstContentPlanMeasurements(a, 4_000)
			setFirstContentPlanMeasurements(b, 4_000)
			plan := firstContentTestPlan(model, a, b)
			plan.entries[0].firstContentFeasible = true
			a.mu.Lock()
			switch change {
			case "rate":
				*a.BackendCapacity.Slots[0].Telemetry.IsolatedPrefillTPS = 400
			case "stale":
				a.capacitySamplesAt = time.Now().Add(-time.Minute)
			case "busy":
				*a.BackendCapacity.Slots[0].Telemetry.PartialPrefillRows = 1
			}
			a.mu.Unlock()
			got, decision, _ := r.ReserveNextFromPlan(firstContentPlanRequest("changed", model), plan)
			if got != b || decision.FirstContent.Status != "feasible" {
				t.Fatalf("%s change not revalidated: provider=%v decision=%+v", change, got, decision)
			}
		})
	}
}

func TestFirstContentPlanRollbackRestoresOrdinaryOrder(t *testing.T) {
	r := New(testLogger())
	if err := r.ConfigureFirstContentRouting(FirstContentRoutingPrefer); err != nil {
		t.Fatal(err)
	}
	const model = "first-content-plan-rollback"
	slow := planTestProvider(t, r, "cheap-slow", model, 0)
	fast := planTestProvider(t, r, "expensive-fast", model, 0)
	setFirstContentPlanMeasurements(slow, 400)
	setFirstContentPlanMeasurements(fast, 4_000)
	slowCandidate := &routingCandidate{provider: slow, costMs: 1, firstContent: FirstContentEstimate{Status: "infeasible"}}
	fastCandidate := &routingCandidate{provider: fast, costMs: 2, firstContent: FirstContentEstimate{Status: "feasible"}}
	pool := []*routingCandidate{slowCandidate, fastCandidate}
	plan := newDispatchPlan(model, candidateScan{pool: pool, planPool: pool, ordinaryPlanPool: pool}, nil)
	if plan.entries[0].provider != fast {
		t.Fatal("fixture did not retain preferred order")
	}
	if err := r.ConfigureFirstContentRouting(FirstContentRoutingOff); err != nil {
		t.Fatal(err)
	}
	got, decision, _ := r.ReserveNextFromPlan(firstContentPlanRequest("rollback", model), plan)
	if got != slow || decision.FirstContentMode != "" {
		t.Fatalf("rollback kept stale preference: provider=%v decision=%+v", got, decision)
	}
}

func TestFirstContentPlanPreservesQuoteOrderWithinFeasibleTier(t *testing.T) {
	r := New(testLogger())
	if err := r.ConfigureFirstContentRouting(FirstContentRoutingPrefer); err != nil {
		t.Fatal(err)
	}
	const model = "first-content-plan-quotes"
	a := planTestProvider(t, r, "unprobed", model, 0)
	b := planTestProvider(t, r, "confirmed", model, 0)
	setFirstContentPlanMeasurements(a, 4_000)
	setFirstContentPlanMeasurements(b, 4_000)
	plan := firstContentTestPlan(model, a, b)
	plan.ConfirmEntry(b.ID, &protocol.CapacityQuoteMessage{AdmissibleNow: true, TTFTP90MS: 9_000})
	got, _, _ := r.ReserveNextFromPlan(firstContentPlanRequest("quote", model), plan)
	if got != b {
		t.Fatalf("provider=%v, want confirmed feasible alternate", got)
	}
}

func TestFirstContentPlanRetainsFeasibleAlternatesBeforeCheapFallbacks(t *testing.T) {
	winner := &routingCandidate{provider: &Provider{ID: "winner"}, firstContent: FirstContentEstimate{Status: "feasible"}}
	fast := &routingCandidate{provider: &Provider{ID: "fast"}, costMs: 1000, firstContent: FirstContentEstimate{Status: "feasible"}}
	fallbacks := []*routingCandidate{winner, fast}
	for i := range 12 {
		fallbacks = append(fallbacks, &routingCandidate{
			provider: &Provider{ID: fmt.Sprintf("fallback-%d", i)}, costMs: float64(i + 1),
			firstContent: FirstContentEstimate{Status: "unknown"},
		})
	}
	plan := newDispatchPlan("model", candidateScan{pool: []*routingCandidate{winner, fast}, planPool: fallbacks}, winner)
	if plan.Len() != dispatchPlanMaxAlternates || plan.entries[0].provider != fast.provider {
		t.Fatalf("feasible alternate crowded out: %+v", plan.entries)
	}
}

func TestFirstContentPlanConcurrentConsumersClaimEachProviderOnce(t *testing.T) {
	forEachCommitMode(t, func(t *testing.T, mode reserveCommitMode) {
		r := New(testLogger())
		setReserveCommitModeForTest(r, mode)
		if err := r.ConfigureFirstContentRouting(FirstContentRoutingPrefer); err != nil {
			t.Fatal(err)
		}
		const model = "first-content-plan-concurrent"
		a := planTestProvider(t, r, "a", model, 0)
		b := planTestProvider(t, r, "b", model, 0)
		setFirstContentPlanMeasurements(a, 4_000)
		setFirstContentPlanMeasurements(b, 4_000)
		plan := firstContentTestPlan(model, a, b)
		var workers sync.WaitGroup
		got := make(chan string, 12)
		for i := range 12 {
			workers.Add(1)
			go func() {
				defer workers.Done()
				provider, _, _ := r.ReserveNextFromPlan(firstContentPlanRequest(fmt.Sprintf("concurrent-%d", i), model), plan)
				if provider != nil {
					got <- provider.ID
				}
			}()
		}
		workers.Wait()
		close(got)
		seen := map[string]int{}
		for id := range got {
			seen[id]++
		}
		if seen[a.ID] != 1 || seen[b.ID] != 1 || plan.Remaining() != 0 {
			t.Fatalf("claims=%v remaining=%d", seen, plan.Remaining())
		}
	})
}
