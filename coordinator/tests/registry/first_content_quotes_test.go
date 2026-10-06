package registry_test

import (
	"fmt"
	"math"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityquote"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func firstContentQuotePlan(t *testing.T, count int, writers ...string) (*quoteRegistryFixture, *production.QuotePlan, []*production.Provider) {
	t.Helper()
	f := newQuoteRegistryFixture(t, writers...)
	entries := make([]production.QuoteCandidate, 0, count)
	providers := make([]*production.Provider, 0, count)
	for i := range count {
		id := fmt.Sprintf("quote-%d", i)
		provider := f.registry.Register(id, nil, testRegisterMessage())
		setQuoteCapable(f.registry, provider)
		entries = append(entries, production.QuoteCandidate{PlanEntry: production.PlanEntry{
			CandidateBinding: production.BindCandidate(provider, seqTestModel), ProviderID: id,
		}})
		providers = append(providers, provider)
	}
	return f, production.NewQuotePlan(entries, "", nil), providers
}

func TestFirstContentQuoteFanoutBoundAndNoReservation(t *testing.T) {
	f, plan, providers := firstContentQuotePlan(t, 5, "quote-0", "quote-1")
	r := f.registry
	a, b := f.clients["quote-0"], f.clients["quote-1"]
	ch := r.ProbePlanCandidates(plan, production.CapacityProbeShape{Model: seqTestModel}, time.Second)
	qa, qb := readProbeFrame(t, a), readProbeFrame(t, b)
	if got := f.tracker.Len(); got != 2 {
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
	for _, provider := range providers {
		pending := provider.PendingCount()
		if pending != 0 {
			t.Fatal("quote reserved work")
		}
	}
}

func TestFirstContentQuoteUsesOriginalDeadline(t *testing.T) {
	f, plan, _ := firstContentQuotePlan(t, 1, "quote-0")
	r, conn := f.registry, f.clients["quote-0"]
	deadline := time.Now().Add(100 * time.Millisecond)
	ch := r.ProbePlanCandidates(plan, production.CapacityProbeShape{
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
	if f.tracker.Len() != 0 {
		t.Fatal("expired request leaked probe correlation")
	}
}

func TestFirstContentFreshQuoteReplacesEarlierRefusal(t *testing.T) {
	f, plan, _ := firstContentQuotePlan(t, 2, "quote-1")
	r, conn := f.registry, f.clients["quote-1"]
	plan.DemoteEntry("quote-1")
	cutoff := time.Now()
	ch := r.ProbePlanCandidates(plan, production.CapacityProbeShape{
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
		_, plan, _ := firstContentQuotePlan(t, 1)
		plan.ApplyQuoteDelivery(capacityquote.Delivery{ProviderID: "quote-0", Quote: testQuote("q", true, bad)})
		if _, _, confirmed := plan.BestConfirmedBackup(); confirmed {
			t.Fatalf("invalid p90=%v confirmed backup", bad)
		}
	}
}

func TestQuoteTrackerSweepSettlesLiveCollector(t *testing.T) {
	now := time.Now()
	clock := now.Add(-2 * time.Hour)
	tracker := capacityquote.New(func() time.Time { return clock }, nil)
	expires := now.Add(time.Hour)
	for i := range 1025 {
		tracker.Add(fmt.Sprintf("live-%d", i), &capacityquote.Pending{ExpiresAt: expires})
	}
	delivery := make(chan capacityquote.Delivery, 1)
	tracker.Add("delayed-collector", &capacityquote.Pending{
		ProviderID: "provider", ExpiresAt: now.Add(-time.Second), Deliver: delivery,
	})
	// Registration uses the earlier clock so the original expired input remains
	// for the triggering add, rather than being swept before it is registered.
	clock = now
	tracker.Add("trigger-sweep", &capacityquote.Pending{ExpiresAt: expires})
	select {
	case got := <-delivery:
		if got.QuoteID != "delayed-collector" || got.ProviderID != "provider" || got.Quote != nil {
			t.Fatalf("expiry settlement=%+v", got)
		}
	default:
		t.Fatal("sweep reclaimed a live collector's entry without settling it")
	}
	if tracker.Take("delayed-collector") != nil {
		t.Fatal("swept quote can settle twice")
	}
}
