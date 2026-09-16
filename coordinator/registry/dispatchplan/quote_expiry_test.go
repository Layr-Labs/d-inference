package dispatchplan

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestQuoteTrackerSweepSettlesLiveCollector(t *testing.T) {
	var tracker Probes[string]
	var plan Plan[string]
	const model = "swept-quote-model"
	const alternate = "alternate"
	builder := plan.Initialize(model, 2, 2, 2)
	builder.Attempted("primary")
	builder.Offer(400, func() Retained[string] {
		return Retained[string]{Connection: alternate, View: Entry{ProviderID: alternate, CostMs: 400}}
	})
	frames := make(chan []byte, 1)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	out := tracker.Probe(&plan, ProbeShape{Model: model}, time.Hour, Transport[string]{
		Ready:  func(string) bool { return true },
		Write:  func(_ string, _ context.Context, payload []byte) error { frames <- payload; return nil },
		Logger: func() *slog.Logger { return logger },
	})
	t.Cleanup(func() { tracker.FailProvider(alternate) })
	var probe protocol.CapacityProbeMessage
	select {
	case payload := <-frames:
		if err := json.Unmarshal(payload, &probe); err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("probe was not sent")
	}

	// Advance just this quote's expiry, then force the opportunistic sweep
	// before its collector's timer runs. No scheduler timing race is needed.
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
		if !result.Timeout || result.SendFailed || result.Quote != nil || result.ProviderID != alternate {
			t.Fatalf("swept outcome = %+v, want timeout for %s", result, alternate)
		}
		if !plan.Entries()[0].View.Demoted {
			t.Fatal("timeout was published before demoting the plan entry")
		}
	case <-time.After(time.Second):
		// Release the collector on the regressed implementation too, so the
		// characterization failure does not leave its hour-long goroutine.
		pending.deliver <- quoteDelivery{quoteID: probe.QuoteID, providerID: alternate}
		select {
		case <-out:
		case <-time.After(time.Second):
			t.Fatal("failed to release expired collector")
		}
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
