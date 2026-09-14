package dispatchplan

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func testQuote(quoteID string, admissible bool, p90ms float64) *protocol.CapacityQuoteMessage {
	q := &protocol.CapacityQuoteMessage{
		Type:                 protocol.TypeCapacityQuote,
		QuoteID:              quoteID,
		CapacitySeq:          1,
		AdmissibleNow:        admissible,
		TTFTP50MS:            p90ms / 2,
		TTFTP90MS:            p90ms,
		AvailableTokenBudget: 50_000,
		Confidence:           protocol.CapacityConfidenceHigh,
	}
	if !admissible {
		q.RejectionReason = protocol.RejectionReasonTokenBudget
	}
	return q
}

// A provider must not be able to answer another provider's probe: the quote is
// dropped and the entry stays registered for the bound provider's own answer.
func TestHandleCapacityQuoteWrongProviderDropped(t *testing.T) {
	reg := &Probes[string]{}
	deliveries := make(chan quoteDelivery, 1)
	reg.add("q1", &pendingQuote{
		providerID: "pA",
		expiresAt:  time.Now().Add(time.Minute),
		deliver:    deliveries,
	})

	reg.Handle("pB", testQuote("q1", true, 500))
	select {
	case d := <-deliveries:
		t.Fatalf("forged quote from pB delivered: %+v", d)
	default:
	}
	if reg.PendingCount() != 1 {
		t.Fatal("forged quote consumed the real provider's entry")
	}

	// Unknown quote_id: dropped without touching the registered entry.
	reg.Handle("pA", testQuote("q-unknown", true, 500))
	if reg.PendingCount() != 1 {
		t.Fatal("unknown quote_id mutated the tracker")
	}

	// The bound provider's own answer resolves it.
	reg.Handle("pA", testQuote("q1", true, 500))
	select {
	case d := <-deliveries:
		if d.providerID != "pA" || d.quote == nil || !d.quote.AdmissibleNow {
			t.Fatalf("delivery = %+v, want pA's admissible quote", d)
		}
	default:
		t.Fatal("bound provider's quote was not delivered")
	}
	if reg.PendingCount() != 0 {
		t.Fatal("resolved entry not removed from tracker")
	}
}

// TestQuoteTrackerSweepIsTimeGated pins the P1 fix on add's expiry sweep:
// the >1024 size trigger only makes a sweep worth CONSIDERING — the time
// gate (quoteTrackerSweepInterval) must hold sustained over-threshold
// insertion to at most one full scan per window, instead of rescanning the
// whole map under t.mu on every add.
func TestQuoteTrackerSweepIsTimeGated(t *testing.T) {
	var tr Probes[string]
	live := time.Now().Add(time.Hour) // unexpired: a sweep removes nothing
	for i := range 1025 {
		tr.add(fmt.Sprintf("q%04d", i), &pendingQuote{expiresAt: live})
	}
	if tr.sweeps != 0 {
		t.Fatalf("sweeps=%d while filling to the threshold, want 0", tr.sweeps)
	}

	// First over-threshold add: the zero-value lastSweep passes the time
	// gate, so exactly one sweep runs.
	tr.add("over-0", &pendingQuote{expiresAt: live})
	if tr.sweeps != 1 {
		t.Fatalf("sweeps=%d after first over-threshold add, want 1", tr.sweeps)
	}

	// Sustained over-threshold insertion within the window: still one sweep.
	for i := range 64 {
		tr.add(fmt.Sprintf("over-%d", i+1), &pendingQuote{expiresAt: live})
	}
	if tr.sweeps != 1 {
		t.Fatalf("sweeps=%d after 64 in-window adds, want 1 (time-gated)", tr.sweeps)
	}

	// A full window elapses (clock seam: rewind lastSweep) — the next add
	// sweeps again, and the sweep still collects expired entries.
	tr.mu.Lock()
	tr.pending["expired-a"] = &pendingQuote{expiresAt: time.Now().Add(-time.Second)}
	tr.pending["expired-b"] = &pendingQuote{expiresAt: time.Now().Add(-time.Second)}
	tr.lastSweep = time.Now().Add(-2 * quoteTrackerSweepInterval)
	tr.mu.Unlock()
	tr.add("post-window", &pendingQuote{expiresAt: live})
	if tr.sweeps != 2 {
		t.Fatalf("sweeps=%d after the window elapsed, want 2", tr.sweeps)
	}
	tr.mu.Lock()
	_, expAlive := tr.pending["expired-a"]
	_, liveAlive := tr.pending["post-window"]
	tr.mu.Unlock()
	if expAlive || !liveAlive {
		t.Fatalf("post-window sweep: expired retained=%v live dropped=%v", expAlive, !liveAlive)
	}
}
