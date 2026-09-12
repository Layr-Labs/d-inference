package registry

import (
	"fmt"
	"testing"
	"time"
)

func TestQuoteTrackerSweepSettlesLiveCollector(t *testing.T) {
	reg := New(testLogger())
	const model = "swept-quote-model"
	planTestProvider(t, reg, "primary", model, 0)
	alternate := planTestProvider(t, reg, "alternate", model, 400)
	request := planTestRequest("swept-quote", 100, 64)
	request.Model = model
	_, _, plan := reg.ReserveProviderWithPlan(model, request)
	setQuoteCapable(alternate)
	conn := attachTestWriter(t, alternate)
	out := reg.ProbePlanCandidates(plan, CapacityProbeShape{Model: model}, time.Hour)
	probe := readProbeFrame(t, conn)

	// Advance just this quote's expiry, then force the opportunistic sweep
	// before its collector's timer runs. No scheduler timing race is needed.
	tracker := &reg.capacityQuotes
	tracker.mu.Lock()
	pending := tracker.pending[probe.QuoteID]
	pending.expiresAt = time.Now().Add(-time.Second)
	for i := range 1025 {
		tracker.pending[fmt.Sprintf("unexpired-%d", i)] = &pendingQuote{expiresAt: time.Now().Add(time.Hour)}
	}
	tracker.lastSweep = time.Time{}
	tracker.mu.Unlock()
	tracker.add("trigger", &pendingQuote{expiresAt: time.Now().Add(time.Hour)})

	select {
	case result := <-out:
		if !result.Timeout || result.SendFailed || result.Quote != nil || result.ProviderID != alternate.ID {
			t.Fatalf("swept outcome = %+v, want timeout for %s", result, alternate.ID)
		}
		if !plan.entries[0].view.Demoted {
			t.Fatal("timeout was published before demoting the plan entry")
		}
	case <-time.After(time.Second):
		// Release the collector on the regressed implementation too, so the
		// characterization failure does not leave its hour-long goroutine.
		pending.deliver <- quoteDelivery{quoteID: probe.QuoteID, providerID: alternate.ID}
		collectOutcomes(t, out)
		t.Fatal("expiry sweep removed the probe without settling its live collector")
	}
	select {
	case _, open := <-out:
		if open {
			t.Fatal("swept probe produced more than one outcome")
		}
	case <-time.After(time.Second):
		t.Fatal("settled collector did not close its output")
	}
}
