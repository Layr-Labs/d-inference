package registry_test

import (
	"fmt"
	"math/rand"
	"slices"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityquote"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/memorypolicy"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/shortlist"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/admission"
	"github.com/eigeninference/d-inference/coordinator/registry/selection"
)

func TestFirstContentRetainedAffinitySurvivesShortlistAndQuotes(t *testing.T) {
	const affinity = "tenant-scoped-prefix"
	pool := make([]*production.QuoteCandidate, 2*shortlist.MaxAlternates+1)
	for i := range pool {
		p := &production.Provider{ID: fmt.Sprintf("peer-%02d", i)}
		pool[i] = &production.QuoteCandidate{CacheAffinityEligible: true, PlanEntry: production.PlanEntry{
			CandidateBinding: production.BindCandidate(p, "model"), ProviderID: p.ID,
			FirstContent: production.FirstContentEstimate{Status: production.FirstContentFeasible, ExpectedMs: 200, ConservativeMs: 1200},
		}}
	}
	project := func(c *production.QuoteCandidate) selection.Candidate {
		return selection.Candidate{ProviderID: c.ProviderID, ExpectedMs: c.FirstContent.ExpectedMs, AffinityEligible: c.CacheAffinityEligible}
	}
	choose := func(candidates []*production.QuoteCandidate) *production.QuoteCandidate {
		d := selection.Select(candidates, project, rand.Intn, affinity)
		return candidates[d.Winner]
	}
	var want []string
	for rotation := range pool {
		ordered := append(slices.Clone(pool[rotation:]), pool[:rotation]...)
		winner := choose(ordered)
		entries := selection.RetainRanked(ordered, winner, shortlist.MaxAlternates, project, rand.Intn, affinity, func(c *production.QuoteCandidate) production.QuoteCandidate {
			entry := *c
			entry.ForecastAt = time.Now()
			return entry
		})
		order := new(shortlist.Order)
		plan := production.NewQuotePlan(entries, affinity, order)
		if plan.Len() != shortlist.MaxAlternates {
			t.Fatalf("retained %d peers, want bounded %d", plan.Len(), shortlist.MaxAlternates)
		}
		got := quotePlanIDs(order)
		if rotation == 0 {
			want = got
		} else if !slices.Equal(got, want) {
			t.Fatalf("pool order changed retained affinity peers: got %v want %v", got, want)
		}
		for _, id := range got {
			plan.ConfirmEntry(id, &protocol.CapacityQuoteMessage{TTFTP50MS: 100, TTFTP90MS: 200, Confidence: protocol.CapacityConfidenceHigh})
		}
		for i, id := range quotePlanIDs(order) {
			if id != want[i] {
				t.Fatalf("equivalent quotes changed affinity order: at %d got %s want %s", i, id, want[i])
			}
		}
	}
}

func reservationQuoteEvidence(now time.Time) forecast.Evidence {
	return forecast.Evidence{Calibration: performance.CalibrationEvidence{
		HasCapacity: true, ModelLoaded: true, IsolatedPrefillTPS: 2000, IsolatedInitialized: true,
	}, CapacityAcceptedAt: now, PrefillTPS: 2000, DecodeTPS: 100, ObservedDecodeTPS: 100,
		Workload: forecast.Workload{WholeMacKnown: true}}
}

func TestFirstContentPendingReconcilesReportedOverlapAndNewReservations(t *testing.T) {
	now := time.Now()
	acceptedAt := now
	before := &production.PendingRequest{RequestID: "before", Model: "m", EstimatedPromptTokens: 1000, RequestedMaxTokens: 100_000}
	after := &production.PendingRequest{RequestID: "after", Model: "m", EstimatedPromptTokens: 2000, RequestedMaxTokens: 200_000}
	pending := []struct {
		request  *production.PendingRequest
		reserved forecast.PrefillReservation
		at       time.Time
	}{
		{before, forecast.PrefillReservation{Known: true, Tokens: 1000}, now.Add(-time.Second)},
		{after, forecast.PrefillReservation{Known: true, Tokens: 2000}, now.Add(time.Second)},
	}
	snapshot := func(queued int64) float64 {
		var work forecast.PrefillQueue
		for _, p := range pending {
			work.Add(forecast.PendingPrefill{Reservation: p.reserved, EstimatedPromptTokens: p.request.EstimatedPromptTokens,
				CacheParticipates: p.request.CacheRoutingParticipates(), ContentCommitted: p.request.ContentCommittedSafe(),
				ModelMatches: p.request.Model == "m", ReservedAt: p.at}, acceptedAt)
		}
		return work.Ahead(queued, true, 0, 10)
	}
	s := snapshot(1500)
	if got := s; got != 3500 {
		t.Fatalf("work=%v, want max(1500,1000)+2000", got)
	}
	// The next accepted frame includes both reservations. It must replace their
	// overlapping work rather than add another copy of either prompt.
	acceptedAt = now.Add(2 * time.Second)
	s = snapshot(3000)
	if got := s; got != 3000 {
		t.Fatalf("reflected work=%v, want 3000", got)
	}
	before.MarkContentCommitted()
	pending = pending[:1]
	s = snapshot(0)
	if got := s; got != 0 {
		t.Fatalf("retired prefill work=%v, want zero", got)
	}
	if admission.PendingTokenBudget(before.EstimatedPromptTokens, before.RequestedMaxTokens, memorypolicy.DefaultRequestedMaxTokens) != 101000 {
		t.Fatal("first content released physical output commitment")
	}
}

func TestFirstContentReservationRetainsCacheResidualWork(t *testing.T) {
	pr := &production.PendingRequest{EstimatedPromptTokens: 1000, RequestedMaxTokens: 20_000}
	reserved := forecast.ReservePrefill(forecast.Estimate{PromptTokens: 1000, CachedTokens: 900, RestoreMs: 80})
	if !reserved.Known || reserved.Tokens != 100 || reserved.RestoreMS != 80 {
		t.Fatalf("reserved work=%v known=%v restore=%v", reserved.Tokens, reserved.Known, reserved.RestoreMS)
	}
	if admission.PendingTokenBudget(pr.EstimatedPromptTokens, pr.RequestedMaxTokens, memorypolicy.DefaultRequestedMaxTokens) != 21000 {
		t.Fatal("cache forecast weakened physical reservation")
	}
}

func TestFirstContentRetainedPlanReranksCurrentServiceWork(t *testing.T) {
	fixture := newPlanRegistryFixture()
	r := fixture.registry
	model := "first-content-plan-rerank"
	primary := fixture.provider(t, "primary", model, 0)
	ahead := fixture.provider(t, "ahead", model, 400)
	backup := fixture.provider(t, "backup", model, 800)
	p, _, plan := r.ReserveProviderWithPlan(model, planTestRequest("initial", 500, 128))
	if p != primary || plan == nil {
		t.Fatal("missing initial plan")
	}
	primary.RemovePending("initial")
	ahead.AddPending(&production.PendingRequest{RequestID: "new-work", Model: model, EstimatedPromptTokens: 12_000, RequestedMaxTokens: 128})
	selected, _, _ := r.ReserveNextFromPlan(planTestRequest("retry", 500, 128), plan, primary.ID)
	if selected != backup {
		t.Fatalf("selected=%v, want newly faster backup", selected)
	}
	if ahead.GetPending("retry") != nil {
		t.Fatal("stale scan order debited the slower alternate")
	}
}

func TestFirstContentFreshScanAndRetainedPlanPreferFeasibleBeforeVersion(t *testing.T) {
	for _, retained := range []bool{false, true} {
		t.Run(map[bool]string{false: "scan", true: "retained"}[retained], func(t *testing.T) {
			fixture := newPlanRegistryFixture()
			r := fixture.registry
			model := "feasible-before-version"
			feasible := fixture.provider(t, "feasible", model, 0)
			unknown := fixture.provider(t, "unknown", model, 0)
			pr := planTestRequest("request", 500, 128)
			plan := fixture.preparation.planner.ScanCandidates(model, pr, false).Plan(model, nil)
			feasible.SetVersion("0.9.10")
			unknown.SetVersion("0.9.11")
			unknown.Mu().Lock()
			fixture.histories[unknown.ID].Reset()
			unknown.PrefillTPS = 20_000 // The faster unknown must not outrank qualified evidence.
			unknown.Mu().Unlock()
			pr.FirstContentDeadline = time.Now().Add(10 * time.Second)
			pr.Traits.AvoidVersion = "0.9.10"
			var selected *production.Provider
			if retained {
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

func TestFirstContentFreshQuoteCommitsWithoutClockRescan(t *testing.T) {
	for _, intervening := range []bool{false, true} {
		t.Run(map[bool]string{false: "fresh", true: "new_local_work"}[intervening], func(t *testing.T) {
			fixture := newPlanRegistryFixture()
			r := fixture.registry
			model := "first-content-quote-commit"
			p := fixture.provider(t, "quoted", model, 0)
			capacity := p.BackendCapacitySnapshot()
			capacity.CapacitySeq = 1
			r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: capacity})
			observedAt := time.Now()
			p.Mu().Lock()
			p.CapacityAcceptedAt = observedAt.Add(-2 * time.Millisecond)
			// Fresh local work/performance remains necessary; the quote alone
			// supplies readiness evidence after this request's refusal cutoff.
			p.Mu().Unlock()
			plan := fixture.preparation.planner.ScanCandidates(model, planTestRequest("retry", 100, 128), false).Plan(model, nil)
			// Make the three evidence times explicitly ordered: adjacent Now
			// calls may share a clock tick and fail a strict post-refusal cutoff.
			cutoff := observedAt.Add(-time.Millisecond)
			plan.ApplyQuoteDelivery(capacityquote.Delivery{ProviderID: p.ID, Quote: &protocol.CapacityQuoteMessage{CapacitySeq: 1, AdmissibleNow: true, TTFTP50MS: 100, TTFTP90MS: 200, Confidence: protocol.CapacityConfidenceHigh}, ObservedAt: observedAt})
			if intervening {
				p.AddPending(&production.PendingRequest{RequestID: "intervening", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 128})
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

func TestFirstContentQuoteCannotRenewUnknownMeasurementsOrWork(t *testing.T) {
	now := time.Now()
	for _, tc := range []struct {
		name   string
		change func(*forecast.Evidence)
	}{
		{"stale_performance", func(c *forecast.Evidence) { c.Calibration.PerformanceAgeMS = 180000 }},
		{"missing_performance", func(c *forecast.Evidence) { c.Calibration.PerformanceAgeMS = -1 }},
		{"busy_other_model", func(c *forecast.Evidence) { c.Workload.WholeMacBusy = true; c.Workload.OtherModelOccupancy = 1 }},
		{"partial_prefill", func(c *forecast.Evidence) { c.Workload.PartialPrefillRows = 1 }},
		{"old_capacity", func(c *forecast.Evidence) { c.Calibration.CapacityAgeMS = 6000 }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			pr := forecast.Request{PromptTokens: 1000, UpperBoundTokens: 1000, Incoming: performance.IncomingWork{RequestedMaxTokens: 128}, Deadline: now.Add(10 * time.Second), RequireFreshFeasible: true, FreshAfter: now.Add(-time.Millisecond)}
			c := reservationQuoteEvidence(now.Add(-2 * time.Millisecond))
			tc.change(&c)
			result := forecast.Evaluate(&c, pr, now)
			estimate := forecast.ApplyQuote(result, &c, pr, forecast.Quote{Confirmed: true, Confidence: protocol.CapacityConfidenceHigh, ObservedAt: now, TTFTP50: time.Millisecond, TTFTP90: 2 * time.Millisecond}, forecast.QuoteContext{}, now)
			if estimate.Status != forecast.Unknown || forecast.Allows(estimate, pr, c.Workload.WholeMacBusy) {
				t.Fatalf("fresh reply renewed invalid evidence: %+v", estimate)
			}
		})
	}
}

func TestFirstContentQuoteCannotUndercutCurrentCacheAdjustedWork(t *testing.T) {
	now := time.Now()
	pr := forecast.Request{PromptTokens: 4000, UpperBoundTokens: 4000, Incoming: performance.IncomingWork{RequestedMaxTokens: 128}, Deadline: now.Add(2 * time.Second), RequireFreshFeasible: true, FreshAfter: now.Add(-time.Millisecond)}
	c := reservationQuoteEvidence(now.Add(-2 * time.Millisecond))
	forecast.CacheBenefit{Tokens: 2000, Weight: 1, RestoreMS: 80, ExpiresAt: now.Add(time.Minute)}.Apply(&pr, now)
	result := forecast.Evaluate(&c, pr, now)
	local := result.Estimate
	estimate := forecast.ApplyQuote(result, &c, pr, forecast.Quote{Confirmed: true, Confidence: protocol.CapacityConfidenceHigh, ObservedAt: now, TTFTP50: time.Millisecond, TTFTP90: 2 * time.Millisecond}, forecast.QuoteContext{}, now)
	if estimate.ExpectedMs != local.ExpectedMs || estimate.ConservativeMs != local.ConservativeMs || estimate.Status != forecast.PredictedLate {
		t.Fatalf("historically cached quote undercut current work: local=%+v quote=%+v", local, estimate)
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
			quote := forecast.Quote{Confirmed: true, Confidence: protocol.CapacityConfidenceHigh,
				ObservedAt: now, TTFTP50: time.Millisecond, TTFTP90: 2 * time.Millisecond}
			estimate := forecast.Estimate{ExpectedMs: 200, ConservativeMs: 1200, PerformanceAgeMs: tc.performanceMs}
			duration, ok := forecast.BackupTiming(estimate, tc.qualified, tc.forecastAt, quote, time.Now())
			if ok != tc.want || (ok && duration != 1200*time.Millisecond) {
				t.Fatalf("backup timing renewed or undercut local evidence: duration=%v ok=%v", duration, ok)
			}
		})
	}
}
