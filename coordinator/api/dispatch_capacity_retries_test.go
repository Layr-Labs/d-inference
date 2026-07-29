package api

// Regression tests for the capacity-retries-exhausted split.
//
// Running out of maxCapacityClassRetries is evidence that the FLEET is busy,
// not that the REQUEST is unservable. Until this change both verdicts wrote
// reason_code "oversized_request", and the exhausted ladder hard-wrote
// candidateCount = 0 into the rejection ledger — from which
// recordRejection derives could_have_served. So every busy-fleet 429 was
// booked as "zero candidates, could not have served" when in fact three
// providers had been dispatched to and had merely been full. That misreporting
// is what pointed the 2026-07 paged-rollout incident at prompt sizes for an
// hour while the actual cause was KV pool exhaustion.

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// exhaustedState builds the dispatchState the exhausted ladder reaches, with
// the inbound request rejectionInfo reads its endpoint and key from.
func exhaustedState(t *testing.T, s *Server, reason string, retries int, decision registry.RoutingDecision) *dispatchState {
	t.Helper()
	return &dispatchState{
		s: s, r: httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil),
		model: "m", publicModel: "m",
		unservable:       reason != "",
		unservableReason: reason,
		capacityRetries:  retries,
		lastDecision:     decision,
	}
}

// transientCapacityMsg is a provider terminal of the shape the paged fleet
// returns when its KV pool is full: a 503 whose text is capacity-class but
// whose implied budget says nothing about the request being too big.
func transientCapacityMsg() protocol.InferenceErrorMessage {
	return protocol.InferenceErrorMessage{
		RequestID:  "req-cap",
		Error:      "request rejected: queue full",
		StatusCode: 503,
	}
}

// The two verdicts must not share a reason code — the whole point of the
// split is that a ledger query can separate them.
func TestCapacityRetriesReasonIsDistinctFromOversized(t *testing.T) {
	if rejectionReasonCapacityRetriesExhausted == rejectionReasonOversized {
		t.Fatal("capacity exhaustion and unservable shapes must carry different reason codes")
	}
	if rejectionReasonCapacityRetriesExhausted == "" {
		t.Fatal("the capacity reason code must be non-empty (it reaches the ledger verbatim)")
	}
}

// Exhausting the transient-capacity retry budget latches the CAPACITY reason;
// a deterministic context overflow still latches oversized_request. Same stop
// behaviour, different verdict.
func TestShouldStopFailoverSplitsCapacityFromUnservable(t *testing.T) {
	t.Run("transient capacity exhausts its retries", func(t *testing.T) {
		d := &dispatchState{s: newTestServerForDispatch(t), model: "m"}
		for i := 1; i < maxCapacityClassRetries; i++ {
			d.setLastInferenceError(nil, transientCapacityMsg())
			if d.shouldStopFailover() {
				t.Fatalf("attempt %d: must keep failing over below the cap", i)
			}
		}
		d.setLastInferenceError(nil, transientCapacityMsg())
		if !d.shouldStopFailover() {
			t.Fatal("must stop at maxCapacityClassRetries")
		}
		if !d.unservable {
			t.Fatal("the stop must still latch the uptime-neutral 429 path")
		}
		if d.unservableReason != rejectionReasonCapacityRetriesExhausted {
			t.Fatalf("reason = %q, want %q — a busy fleet is not an unservable request",
				d.unservableReason, rejectionReasonCapacityRetriesExhausted)
		}
		if d.capacityRetries != maxCapacityClassRetries {
			t.Fatalf("capacityRetries = %d, want %d", d.capacityRetries, maxCapacityClassRetries)
		}
	})

	t.Run("deterministic overflow stays oversized_request", func(t *testing.T) {
		d := &dispatchState{s: newTestServerForDispatch(t), model: "m"}
		// Unknown budget + unknown context ⇒ a "batch token budget" reject is
		// deterministic: every provider rejects it identically.
		d.setLastInferenceError(nil, protocol.InferenceErrorMessage{
			Error: "token_budget_exhausted: request exceeds batch token budget", StatusCode: 503,
		})
		if !d.shouldStopFailover() {
			t.Fatal("a deterministic overflow must stop on the first occurrence")
		}
		if d.unservableReason != rejectionReasonOversized {
			t.Fatalf("reason = %q, want %q — oversized_request stays reserved for unservable shapes",
				d.unservableReason, rejectionReasonOversized)
		}
	})
}

// The exhausted ladder's ledger record must carry the counters the scheduler
// actually produced on the capacity path, and an authoritative zero only on
// the genuinely-unservable path.
func TestExhaustedRejectionInfoCounterfactual(t *testing.T) {
	decision := registry.RoutingDecision{
		CandidateCount:     5,
		CapacityRejections: 4,
		BestTTFTMs:         1234,
	}

	t.Run("capacity path reports the real counts", func(t *testing.T) {
		d := exhaustedState(t, newTestServerForDispatch(t),
			rejectionReasonCapacityRetriesExhausted, maxCapacityClassRetries, decision)
		info := d.exhaustedRejectionInfo(rejectionReasonCapacityRetriesExhausted, http.StatusTooManyRequests, 2000)
		if !info.servabilityComputed {
			t.Fatal("the caller already knows the counterfactual; it must not be recomputed")
		}
		if info.candidateCount != 5 || info.capacityRejections != 4 {
			t.Fatalf("(candidates=%d, capacityRejections=%d), want (5, 4)",
				info.candidateCount, info.capacityRejections)
		}
		if info.bestTTFTMs != 1234 {
			t.Fatalf("bestTTFTMs = %v, want 1234", info.bestTTFTMs)
		}
	})

	t.Run("capacity path floors on providers that actually rejected", func(t *testing.T) {
		// A decision with no counters (every candidate already excluded on the
		// final attempt) must not erase the fact that three providers were
		// dispatched to and capacity-rejected.
		d := exhaustedState(t, newTestServerForDispatch(t),
			rejectionReasonCapacityRetriesExhausted, maxCapacityClassRetries, registry.RoutingDecision{})
		info := d.exhaustedRejectionInfo(rejectionReasonCapacityRetriesExhausted, http.StatusTooManyRequests, 2000)
		if info.candidateCount != maxCapacityClassRetries {
			t.Fatalf("candidateCount = %d, want the observed floor %d", info.candidateCount, maxCapacityClassRetries)
		}
		if info.capacityRejections != maxCapacityClassRetries {
			t.Fatalf("capacityRejections = %d, want the observed floor %d", info.capacityRejections, maxCapacityClassRetries)
		}
	})

	t.Run("unservable path keeps its authoritative zero", func(t *testing.T) {
		d := exhaustedState(t, newTestServerForDispatch(t), rejectionReasonOversized, 1, decision)
		info := d.exhaustedRejectionInfo(rejectionReasonOversized, http.StatusTooManyRequests, 2000)
		if !info.servabilityComputed || info.candidateCount != 0 {
			t.Fatalf("(computed=%v, candidates=%d), want (true, 0) — every candidate would reject this shape",
				info.servabilityComputed, info.candidateCount)
		}
	})

	t.Run("non-unservable exits defer the counterfactual", func(t *testing.T) {
		d := exhaustedState(t, newTestServerForDispatch(t), "", 0, decision)
		info := d.exhaustedRejectionInfo("dispatch_exhausted", http.StatusServiceUnavailable, 0)
		if info.servabilityComputed {
			t.Fatal("a plain dispatch_exhausted exit must let recordRejection compute servability off the request path")
		}
	})
}

// The headline consequence, through the real ledger write: a capacity-exhausted
// rejection must persist could_have_served = true, and an unservable one false.
func TestRejectionLedgerCouldHaveServedSplit(t *testing.T) {
	for _, tc := range []struct {
		name            string
		reason          string
		wantCouldServe  bool
		wantCandidates  int
		wantCapRejected int
	}{
		{
			name: "capacity exhausted", reason: rejectionReasonCapacityRetriesExhausted,
			wantCouldServe: true, wantCandidates: 5, wantCapRejected: 4,
		},
		{
			name: "unservable shape", reason: rejectionReasonOversized,
			wantCouldServe: false, wantCandidates: 0, wantCapRejected: 0,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := newTestServerForDispatch(t)
			d := exhaustedState(t, s, tc.reason, maxCapacityClassRetries,
				registry.RoutingDecision{CandidateCount: 5, CapacityRejections: 4})
			s.recordRejection(d.exhaustedRejectionInfo(tc.reason, http.StatusTooManyRequests, 2000))

			rec := waitForRejection(t, s.store, tc.reason)
			if rec.CouldHaveServed != tc.wantCouldServe {
				t.Fatalf("could_have_served = %v, want %v", rec.CouldHaveServed, tc.wantCouldServe)
			}
			if rec.CandidateCount != tc.wantCandidates {
				t.Fatalf("candidate_count = %d, want %d", rec.CandidateCount, tc.wantCandidates)
			}
			if rec.CapacityRejections != tc.wantCapRejected {
				t.Fatalf("capacity_rejections = %d, want %d", rec.CapacityRejections, tc.wantCapRejected)
			}
		})
	}
}

// noteDecision must not let a signal-free tail attempt erase what earlier
// attempts saw — that erasure would reintroduce the zero-candidate report the
// floor is only a backstop for.
func TestNoteDecisionKeepsSignalBearingScan(t *testing.T) {
	d := &dispatchState{s: newTestServerForDispatch(t), model: "m"}
	d.noteDecision(registry.RoutingDecision{CandidateCount: 7, CapacityRejections: 2})
	d.noteDecision(registry.RoutingDecision{})
	if d.lastDecision.CandidateCount != 7 || d.lastDecision.CapacityRejections != 2 {
		t.Fatalf("lastDecision = %+v, want the earlier signal-bearing scan retained", d.lastDecision)
	}
	d.noteDecision(registry.RoutingDecision{ProviderID: "p", CandidateCount: 1})
	if d.lastDecision.ProviderID != "p" || d.lastDecision.CandidateCount != 1 {
		t.Fatalf("lastDecision = %+v, want the newer signal-bearing scan", d.lastDecision)
	}
}

// waitForRejection polls the rejection ledger for a record with the given
// reason code. recordRejection writes on the telemetry sink, so the write is
// asynchronous by design.
func waitForRejection(t *testing.T, st store.Store, reason string) store.RejectionRecord {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		for _, rec := range st.RejectionRecordsSince(time.Time{}) {
			if rec.ReasonCode == reason {
				return rec
			}
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("no rejection record with reason %q was persisted", reason)
	return store.RejectionRecord{}
}
