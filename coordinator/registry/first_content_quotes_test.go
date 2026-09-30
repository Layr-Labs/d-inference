package registry

import (
	"fmt"
	"math"
	"testing"
	"time"
)

func firstContentQuotePlan(t *testing.T, count int) (*Registry, *DispatchPlan) {
	t.Helper()
	r := New(testLogger())
	p := &DispatchPlan{model: seqTestModel, attempted: make(map[string]struct{})}
	for i := range count {
		id := fmt.Sprintf("quote-%d", i)
		provider := r.Register(id, nil, testRegisterMessage())
		setQuoteCapable(provider)
		p.entries = append(p.entries, planEntry{provider: provider, view: PlanEntry{ProviderID: id}})
	}
	return r, p
}

func TestFirstContentQuoteFanoutBoundAndNoReservation(t *testing.T) {
	r, plan := firstContentQuotePlan(t, 5)
	a := attachTestWriter(t, plan.entries[0].provider)
	b := attachTestWriter(t, plan.entries[1].provider)
	ch := r.ProbePlanCandidates(plan, CapacityProbeShape{Model: seqTestModel}, time.Second)
	qa, qb := readProbeFrame(t, a), readProbeFrame(t, b)
	if got := trackerLen(r); got != 2 {
		t.Fatalf("concurrent probes = %d, want 2", got)
	}
	r.HandleCapacityQuote("quote-0", testQuote(qa.QuoteID, true, 100))
	r.HandleCapacityQuote("quote-1", testQuote(qb.QuoteID, true, 100))
	if outcomes := collectOutcomes(t, ch); len(outcomes) != 2 {
		t.Fatalf("outcomes = %d, want only two targets", len(outcomes))
	}
	if plan.Remaining() != 5 {
		t.Fatal("quotes consumed a plan entry")
	}
	for _, entry := range plan.entries {
		entry.provider.mu.Lock()
		pending := len(entry.provider.pendingReqs)
		entry.provider.mu.Unlock()
		if pending != 0 {
			t.Fatal("quote reserved work")
		}
	}
}

func TestFirstContentQuoteUsesOriginalDeadline(t *testing.T) {
	r, plan := firstContentQuotePlan(t, 1)
	conn := attachTestWriter(t, plan.entries[0].provider)
	deadline := time.Now().Add(100 * time.Millisecond)
	ch := r.ProbePlanCandidates(plan, CapacityProbeShape{
		Model: seqTestModel, DeadlineRemaining: time.Hour,
		FirstContentDeadline: deadline,
	}, 5*time.Second)
	probe := readProbeFrame(t, conn)
	if probe.DeadlineRemainingMS <= 0 || probe.DeadlineRemainingMS > 100 {
		t.Fatalf("wire deadline = %d ms, want original <=100 ms", probe.DeadlineRemainingMS)
	}
	if outcomes := collectOutcomes(t, ch); !outcomes["quote-0"].Timeout {
		t.Fatalf("silent probe = %+v, want timeout", outcomes)
	}
	if time.Since(deadline) > time.Second {
		t.Fatal("quote wait reset the original deadline")
	}
	if trackerLen(r) != 0 {
		t.Fatal("expired request leaked probe correlation")
	}
}

func TestFirstContentFreshQuoteReplacesEarlierRefusal(t *testing.T) {
	r, plan := firstContentQuotePlan(t, 2)
	conn := attachTestWriter(t, plan.entries[1].provider)
	plan.DemoteEntry("quote-1")
	cutoff := time.Now()
	ch := r.ProbePlanCandidates(plan, CapacityProbeShape{
		Model: seqTestModel, RefreshEvidence: true,
		ExcludedProviderIDs: []string{"quote-0"},
	}, time.Second)
	probe := readProbeFrame(t, conn)
	r.HandleCapacityQuote("quote-1", testQuote(probe.QuoteID, true, 100))
	if outcomes := collectOutcomes(t, ch); len(outcomes) != 1 || outcomes["quote-1"].Quote == nil {
		t.Fatalf("fresh outcomes = %+v", outcomes)
	}
	view, ok := plan.PeekNext()
	if !ok || view.ProviderID != "quote-1" || !view.Confirmed || !view.QuoteObservedAt.After(cutoff) || view.QuoteCapacitySeq != 1 {
		t.Fatalf("fresh evidence = %+v", view)
	}
}

func TestFirstContentInvalidQuoteCannotConfirm(t *testing.T) {
	for _, bad := range []float64{-1, 0, math.NaN(), math.Inf(1)} {
		_, plan := firstContentQuotePlan(t, 1)
		applyQuoteDelivery(plan, quoteDelivery{providerID: "quote-0", quote: testQuote("q", true, bad)})
		if _, _, confirmed := plan.BestConfirmedBackup(); confirmed {
			t.Fatalf("invalid p90=%v confirmed backup", bad)
		}
	}
}

func TestQuoteTrackerSweepSettlesLiveCollector(t *testing.T) {
	var tracker quoteTracker
	expires := time.Now().Add(time.Hour)
	for i := range 1025 {
		tracker.add(fmt.Sprintf("live-%d", i), &pendingQuote{expiresAt: expires})
	}
	delivery := make(chan quoteDelivery, 1)
	tracker.pending["delayed-collector"] = &pendingQuote{
		providerID: "provider", expiresAt: time.Now().Add(-time.Second), deliver: delivery,
	}
	tracker.add("trigger-sweep", &pendingQuote{expiresAt: expires})
	select {
	case got := <-delivery:
		if got.quoteID != "delayed-collector" || got.providerID != "provider" || got.quote != nil {
			t.Fatalf("expiry settlement=%+v", got)
		}
	default:
		t.Fatal("sweep reclaimed a live collector's entry without settling it")
	}
	if tracker.take("delayed-collector") != nil {
		t.Fatal("swept quote can settle twice")
	}
}
