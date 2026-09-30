package registry

import (
	"fmt"
	"slices"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestFirstContentPendingReconcilesReportedOverlapAndNewReservations(t *testing.T) {
	now := time.Now()
	p := &Provider{CapacityAcceptedAt: now, pendingReqs: map[string]*PendingRequest{}}
	before := &PendingRequest{RequestID: "before", Model: "m", EstimatedPromptTokens: 1000, RequestedMaxTokens: 100_000,
		reservedPrefillKnown: true, reservedPrefillTokens: 1000, reservedAt: now.Add(-time.Second)}
	after := &PendingRequest{RequestID: "after", Model: "m", EstimatedPromptTokens: 2000, RequestedMaxTokens: 200_000,
		reservedPrefillKnown: true, reservedPrefillTokens: 2000, reservedAt: now.Add(time.Second)}
	p.pendingReqs[before.RequestID], p.pendingReqs[after.RequestID] = before, after
	snapshot := func(queued int64) routingSnapshot {
		s := routingSnapshot{firstContentPendingKnown: true, queuedPrefillTokens: queued,
			firstContentSnapshot: firstContentSnapshot{queuedPrefillKnown: true}}
		fillFirstContentPending(&s, p, "m")
		return s
	}
	s := snapshot(1500)
	if got := firstContentPrefillAhead(&s, 10); got != 3500 {
		t.Fatalf("work=%v, want max(1500,1000)+2000", got)
	}
	// The next accepted frame includes both reservations. It must replace their
	// overlapping work rather than add another copy of either prompt.
	p.CapacityAcceptedAt = now.Add(2 * time.Second)
	s = snapshot(3000)
	if got := firstContentPrefillAhead(&s, 10); got != 3000 {
		t.Fatalf("reflected work=%v, want 3000", got)
	}
	before.MarkContentCommitted()
	delete(p.pendingReqs, after.RequestID)
	s = snapshot(0)
	if got := firstContentPrefillAhead(&s, 10); got != 0 {
		t.Fatalf("retired prefill work=%v, want zero", got)
	}
	if pendingTokenBudget(before) != 101000 {
		t.Fatal("first content released physical output commitment")
	}
}

func TestFirstContentReservationRetainsCacheResidualWork(t *testing.T) {
	pr := &PendingRequest{EstimatedPromptTokens: 1000, RequestedMaxTokens: 20_000}
	recordReservedPrefill(pr, &routingCandidate{firstContent: FirstContentEstimate{PromptTokens: 1000, CachedTokens: 900, RestoreMs: 80}})
	if !pr.reservedPrefillKnown || pr.reservedPrefillTokens != 100 || pr.reservedPrefillRestoreMs != 80 {
		t.Fatalf("reserved work=%v known=%v restore=%v", pr.reservedPrefillTokens, pr.reservedPrefillKnown, pr.reservedPrefillRestoreMs)
	}
	if pendingTokenBudget(pr) != 21000 {
		t.Fatal("cache forecast weakened physical reservation")
	}
}

func TestFirstContentRetainedPlanReranksCurrentServiceWork(t *testing.T) {
	r := New(testLogger())
	model := "first-content-plan-rerank"
	primary := planTestProvider(t, r, "primary", model, 0)
	ahead := planTestProvider(t, r, "ahead", model, 400)
	backup := planTestProvider(t, r, "backup", model, 800)
	p, _, plan := r.ReserveProviderWithPlan(model, planTestRequest("initial", 500, 128))
	if p != primary || plan == nil {
		t.Fatal("missing initial plan")
	}
	primary.RemovePending("initial")
	ahead.AddPending(&PendingRequest{RequestID: "new-work", Model: model, EstimatedPromptTokens: 12_000, RequestedMaxTokens: 128})
	selected, _, _ := r.ReserveNextFromPlan(planTestRequest("retry", 500, 128), plan, primary.ID)
	if selected != backup {
		t.Fatalf("selected=%v, want newly faster backup", selected)
	}
	if ahead.GetPending("retry") != nil {
		t.Fatal("stale scan order debited the slower alternate")
	}
}

func TestFirstContentFreshQuoteCommitsWithoutClockRescan(t *testing.T) {
	for _, intervening := range []bool{false, true} {
		t.Run(map[bool]string{false: "fresh", true: "new_local_work"}[intervening], func(t *testing.T) {
			r := New(testLogger())
			model := "first-content-quote-commit"
			p := planTestProvider(t, r, "quoted", model, 0)
			observedAt := time.Now()
			p.mu.Lock()
			p.capacitySeq = 1
			p.CapacityAcceptedAt = observedAt.Add(-2 * time.Millisecond)
			// Fresh local work/performance remains necessary; the quote alone
			// supplies readiness evidence after this request's refusal cutoff.
			p.mu.Unlock()
			plan := &DispatchPlan{model: model, attempted: map[string]struct{}{}, entries: []planEntry{{provider: p, view: PlanEntry{ProviderID: p.ID}}}}
			// Make the three evidence times explicitly ordered: adjacent Now
			// calls may share a clock tick and fail a strict post-refusal cutoff.
			cutoff := observedAt.Add(-time.Millisecond)
			plan.confirmEntryAt(p.ID, &protocol.CapacityQuoteMessage{CapacitySeq: 1, AdmissibleNow: true, TTFTP50MS: 100, TTFTP90MS: 200, Confidence: protocol.CapacityConfidenceHigh}, observedAt)
			if intervening {
				p.AddPending(&PendingRequest{RequestID: "intervening", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 128})
			}
			pr := planTestRequest("retry", 100, 128)
			pr.FirstContentDeadline = time.Now().Add(10 * time.Second)
			pr.RequireFreshFeasible, pr.RequireFreshFeasibleAfter = true, cutoff
			selected, decision, _ := r.ReserveNextFromPlan(pr, plan)
			if intervening {
				if selected != nil || p.GetPending(pr.RequestID) != nil {
					t.Fatal("stale quote bypassed new local work")
				}
			} else if selected != p || decision.FirstContent.Reason != "fresh_quote" || p.GetPending(pr.RequestID) != pr {
				t.Fatalf("fresh quote not committed: selected=%v decision=%+v", selected != nil, decision.FirstContent)
			}
		})
	}
}

func TestFirstContentFreshScanAndRetainedPlanPreferFeasibleBeforeVersion(t *testing.T) {
	for _, retained := range []bool{false, true} {
		t.Run(map[bool]string{false: "scan", true: "retained"}[retained], func(t *testing.T) {
			r := New(testLogger())
			model := "feasible-before-version"
			feasible := planTestProvider(t, r, "feasible", model, 0)
			unknown := planTestProvider(t, r, "unknown", model, 0)
			setProviderVersion(feasible, "0.9.10")
			setProviderVersion(unknown, "0.9.11")
			unknown.mu.Lock()
			unknown.firstContentMeasurements = nil
			unknown.PrefillTPS = 20_000 // The faster unknown must not outrank qualified evidence.
			unknown.mu.Unlock()
			pr := planTestRequest("request", 500, 128)
			pr.FirstContentDeadline = time.Now().Add(10 * time.Second)
			pr.Traits.AvoidVersion = "0.9.10"
			var selected *Provider
			if retained {
				plan := &DispatchPlan{model: model, attempted: map[string]struct{}{}, entries: []planEntry{
					{provider: unknown, view: PlanEntry{ProviderID: unknown.ID}},
					{provider: feasible, view: PlanEntry{ProviderID: feasible.ID}},
				}}
				selected, _, _ = r.ReserveNextFromPlan(pr, plan)
			} else {
				selected, _ = r.ReserveProviderEx(model, pr)
			}
			if selected != feasible {
				t.Fatalf("selected=%v, want feasible before version diversity", selected)
			}
		})
	}
}

func TestFirstContentQuoteCannotRenewUnknownMeasurementsOrWork(t *testing.T) {
	now := time.Now()
	r := New(testLogger())
	for _, tc := range []struct {
		name   string
		change func(*routingCandidate)
	}{
		{"stale_performance", func(c *routingCandidate) { c.snapshot.performanceAgeMs = 180000 }},
		{"missing_performance", func(c *routingCandidate) { c.snapshot.performanceAgeMs = -1 }},
		{"busy_other_model", func(c *routingCandidate) { c.snapshot.wholeMacBusy = true; c.snapshot.otherModelOccupancy = 1 }},
		{"partial_prefill", func(c *routingCandidate) { c.snapshot.partialPrefillRows = 1 }},
		{"old_capacity", func(c *routingCandidate) { c.snapshot.capacityAgeMs = 6000 }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			pr := &PendingRequest{EstimatedPromptTokens: 1000, RequestedMaxTokens: 128, FirstContentDeadline: now.Add(10 * time.Second), RequireFreshFeasible: true, RequireFreshFeasibleAfter: now.Add(-time.Millisecond)}
			c := measuredFirstContentCandidate(now.Add(-2 * time.Millisecond))
			tc.change(c)
			r.estimateFirstContent(c, pr, now)
			applyFirstContentQuote(c, pr, PlanEntry{Confirmed: true, QuoteConfidence: protocol.CapacityConfidenceHigh, QuoteObservedAt: now, QuoteTTFTP50: time.Millisecond, QuoteTTFTP90: 2 * time.Millisecond}, now)
			if c.firstContent.Status != FirstContentUnknown || firstContentCandidateAllowed(c, pr) {
				t.Fatalf("fresh reply renewed invalid evidence: %+v", c.firstContent)
			}
		})
	}
}

func TestFirstContentQuoteCannotUndercutCurrentCacheAdjustedWork(t *testing.T) {
	now := time.Now()
	r := New(testLogger())
	pr := &PendingRequest{EstimatedPromptTokens: 4000, RequestedMaxTokens: 128, FirstContentDeadline: now.Add(2 * time.Second), RequireFreshFeasible: true, RequireFreshFeasibleAfter: now.Add(-time.Millisecond)}
	c := measuredFirstContentCandidate(now.Add(-2 * time.Millisecond))
	c.firstContentCachedTokens, c.firstContentCacheWeight = 2000, 1
	c.firstContentRestoreMs, c.firstContentCacheExpiresAt = 80, now.Add(time.Minute)
	r.estimateFirstContent(c, pr, now)
	local := c.firstContent
	applyFirstContentQuote(c, pr, PlanEntry{Confirmed: true, QuoteConfidence: protocol.CapacityConfidenceHigh, QuoteObservedAt: now, QuoteTTFTP50: time.Millisecond, QuoteTTFTP90: 2 * time.Millisecond}, now)
	if c.firstContent.ExpectedMs != local.ExpectedMs || c.firstContent.ConservativeMs != local.ConservativeMs || c.firstContent.Status != FirstContentPredictedLate {
		t.Fatalf("historically cached quote undercut current work: local=%+v quote=%+v", local, c.firstContent)
	}
}

func TestFirstContentRetainedAffinitySurvivesShortlistAndQuotes(t *testing.T) {
	const affinity = "tenant-scoped-prefix"
	pool := make([]*routingCandidate, 2*dispatchPlanMaxAlternates+1)
	for i := range pool {
		pool[i] = &routingCandidate{provider: &Provider{ID: fmt.Sprintf("peer-%02d", i)}, cacheAffinityEligible: true,
			firstContent: FirstContentEstimate{Status: FirstContentFeasible, ExpectedMs: 200, ConservativeMs: 1200}}
	}
	var want []string
	for rotation := range pool {
		ordered := append(slices.Clone(pool[rotation:]), pool[:rotation]...)
		winner, _, _, _ := selectRoutingCandidateWithAffinity(ordered, affinity)
		plan := newDispatchPlan("model", candidateScan{pool: ordered, affinity: affinity}, winner)
		if plan.Len() != dispatchPlanMaxAlternates {
			t.Fatalf("retained %d peers, want bounded %d", plan.Len(), dispatchPlanMaxAlternates)
		}
		var got []string
		for _, entry := range plan.entries {
			got = append(got, entry.view.ProviderID)
		}
		if rotation == 0 {
			want = got
		} else if !slices.Equal(got, want) {
			t.Fatalf("pool order changed retained affinity peers: got %v want %v", got, want)
		}
		for _, id := range got {
			plan.ConfirmEntry(id, &protocol.CapacityQuoteMessage{TTFTP50MS: 100, TTFTP90MS: 200, Confidence: protocol.CapacityConfidenceHigh})
		}
		for i, entry := range plan.entries {
			if entry.view.ProviderID != want[i] {
				t.Fatalf("equivalent quotes changed affinity order: at %d got %s want %s", i, entry.view.ProviderID, want[i])
			}
		}
	}
}

func TestFirstContentBackupTimingCannotRenewLocalEvidence(t *testing.T) {
	now := time.Now()
	for _, tc := range []struct {
		name          string
		forecastAt    time.Time
		performanceMs int32
		qualified     bool
		want          bool
	}{
		{"fresh", now, 0, true, true},
		{"capacity_expired", now.Add(-6 * time.Second), 0, true, false},
		{"performance_expired", now.Add(-time.Second), 120000, true, false},
		{"unknown", now, 0, false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			plan := &DispatchPlan{entries: []planEntry{{evidenceQualified: tc.qualified, forecastAt: tc.forecastAt,
				view: PlanEntry{ProviderID: "peer", Confirmed: true, QuoteConfidence: protocol.CapacityConfidenceHigh,
					QuoteObservedAt: now, QuoteTTFTP50: time.Millisecond, QuoteTTFTP90: 2 * time.Millisecond,
					FirstContent: FirstContentEstimate{ExpectedMs: 200, ConservativeMs: 1200, PerformanceAgeMs: tc.performanceMs}}}}}
			_, duration, ok := plan.BestConfirmedBackup()
			if ok != tc.want || (ok && duration != 1200*time.Millisecond) {
				t.Fatalf("backup timing renewed or undercut local evidence: duration=%v ok=%v", duration, ok)
			}
		})
	}
}
