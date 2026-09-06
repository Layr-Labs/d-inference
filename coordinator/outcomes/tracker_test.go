package outcomes

import (
	"fmt"
	"sync"
	"testing"
	"time"
)

func accountingFixture() *Tracker {
	return New("incoming", "/v1/chat/completions", time.Now().Add(-time.Second), nil)
}

func sentAttempt(tr *Tracker, id string, ordinal int, backup string) *Attempt {
	a := tr.NewAttempt(id, ordinal, backup)
	a.Observe("write_started", "", 0)
	a.Observe("write_completed", "", 0)
	return a
}

func TestRequestAccountingRecoveredRefusalAndSpeculativeLoser(t *testing.T) {
	for _, speculative := range []bool{false, true} {
		t.Run(fmt.Sprintf("speculative=%t", speculative), func(t *testing.T) {
			tr := accountingFixture()
			a := sentAttempt(tr, "attempt-a", 0, "")
			a.Observe("provider_error", "deadline_unreachable", 503)
			a.Observe("provider_error", "deadline_unreachable", 503)
			backup := ""
			if speculative {
				backup = "attempt-a"
			}
			b := sentAttempt(tr, "attempt-b", 1, backup)
			b.Observe("acknowledged", "", 0)
			b.Observe("content", "", 0)
			b.Observe("committed", "", 0)
			b.Observe("provider_complete", "", 0)
			tr.Egress(true, false, "completed")
			tr.Finish(200, false, false)
			got := tr.Snapshot()
			if got.Termination != "completed" || got.AttemptCount != 2 || got.DispatchedAttemptCount != 2 || got.DeadlineRefusalCount != 1 {
				t.Fatalf("recovered request counted incorrectly: %+v", got)
			}
			if got.NormalizedCode != "" || got.Attempts[0].NormalizedCode != "int_provider_deadline_rejected" || got.Attempts[1].BackupOf != backup || !got.Attempts[1].Winning {
				t.Fatalf("internal/final scope or attempt linkage lost: %+v", got)
			}
		})
	}
}

func TestRequestAccountingFinalReasonIsIndependentOfAttempts(t *testing.T) {
	for _, tc := range []struct {
		reason    string
		exhausted bool
		status    int
		want      string
	}{
		{"deadline_unreachable", true, 429, "ext_coordinator_exhausted"},
		{"first_chunk_timeout", false, 429, "ext_first_content_timeout"},
		{"dispatch_exhausted", true, 503, "ext_coordinator_exhausted"},
		{"dispatch_exhausted", false, 504, ""},
		{"queue_deadline", false, 429, ""},
		{"invalid_request", false, 400, ""},
	} {
		t.Run(fmt.Sprintf("%s/%d/%t", tc.reason, tc.status, tc.exhausted), func(t *testing.T) {
			tr := accountingFixture()
			for i := 0; i < 3; i++ {
				sentAttempt(tr, fmt.Sprint(i), i, "").Observe("provider_error", "deadline_unreachable", 503)
			}
			tr.Rejection(tc.reason, tc.exhausted)
			tr.Finish(tc.status, false, false)
			tr.Finish(200, false, false)
			got := tr.Snapshot()
			if got.Termination != "rejected" || got.NormalizedCode != tc.want || got.RawReason != tc.reason || *got.HTTPStatus != tc.status || got.DeadlineRefusalCount != 3 {
				t.Fatalf("final classification changed by retry history or duplicate finish: %+v", got)
			}
		})
	}
}

func TestRequestAccountingRequiresProviderTerminalAndSuccessfulEgress(t *testing.T) {
	for _, tc := range []struct {
		name, provider, terminal    string
		content, egress, writeError bool
		want                        string
	}{
		{"normal", "provider_complete", "completed", true, true, false, "completed"},
		{"zero tokens", "provider_complete", "completed", false, true, false, "completed"},
		{"missing provider terminal", "", "completed", true, true, false, "interrupted"},
		{"provider failed", "provider_error", "completed", true, true, false, "interrupted"},
		{"no body sent", "provider_complete", "completed", true, false, false, "interrupted"},
		{"short write", "provider_complete", "completed", true, true, true, "interrupted"},
		{"incomplete Responses", "provider_complete", "incomplete", true, true, false, "interrupted"},
		{"error terminal", "provider_complete", "error", true, true, false, "interrupted"},
		{"unknown terminal", "provider_complete", "unknown", true, true, false, "interrupted"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tr := accountingFixture()
			a := sentAttempt(tr, "attempt", 0, "")
			a.Observe("committed", "", 0)
			if tc.content {
				a.Observe("content", "", 0)
			}
			if tc.provider != "" {
				a.Observe(tc.provider, "", 0)
			}
			tr.Egress(tc.egress, tc.writeError, tc.terminal)
			tr.Finish(200, false, false)
			got := tr.Snapshot()
			if got.Termination != tc.want {
				t.Fatalf("got %+v; want %s", got, tc.want)
			}
			if tc.want != "completed" && got.ResponseProgress == "completion_confirmed" {
				t.Fatalf("fabricated completion: %+v", got)
			}
		})
	}
}

func TestRequestAccountingDepartureRetainsLateProviderCompletion(t *testing.T) {
	tr := accountingFixture()
	a := sentAttempt(tr, "parked", 0, "")
	a.Observe("content", "", 0)
	a.Observe("committed", "", 0)
	tr.Finish(200, true, false)
	first := tr.Snapshot()
	if !first.ObservedAt.Equal(*first.FinalizedAt) {
		t.Fatal("initial terminal must not appear late")
	}
	a.Observe("provider_complete", "", 0)
	got := tr.Snapshot()
	if got.Termination != "client_departure" || got.ProviderOutcome != "completed" || got.ResponseEgressCompleted || got.ResponseProgress == "completion_confirmed" || got.Revision <= first.Revision || !got.ObservedAt.After(*got.FinalizedAt) {
		t.Fatalf("departure and late provider evidence were conflated: %+v", got)
	}
	if !got.ReceivedAt.Equal(first.ReceivedAt) || !got.FinalizedAt.Equal(*first.FinalizedAt) {
		t.Fatal("late evidence moved the request's cohort or exit time")
	}
}

func TestRequestAccountingSelectionAndFailedWriteAreNotDispatch(t *testing.T) {
	tr := accountingFixture()
	a := tr.NewAttempt("selection", 0, "")
	a.Observe("not_dispatched", "queue_deadline", 429)
	b := tr.NewAttempt("ambiguous-write", 1, "")
	b.Observe("write_started", "", 0)
	b.Observe("not_dispatched", "provider_error", 503)
	tr.Rejection("queue_deadline", false)
	tr.Finish(429, false, false)
	got := tr.Snapshot()
	if got.DispatchedAttemptCount != 0 || got.Attempts[0].ProviderOutcome != "not_dispatched" || got.Attempts[1].ProviderOutcome != "no_terminal" {
		t.Fatalf("failed write claimed provider receipt/nonreceipt: %+v", got)
	}
}

func TestRequestAccountingConcurrentTerminalIsIdempotent(t *testing.T) {
	tr := accountingFixture()
	a := sentAttempt(tr, "attempt", 0, "")
	a.Observe("committed", "", 0)
	tr.Egress(true, false, "completed")
	var wg sync.WaitGroup
	for i := 0; i < 32; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			a.Observe("write_completed", "", 0)
			a.Observe("provider_complete", "", 0)
			tr.Finish(200, false, false)
		}()
	}
	wg.Wait()
	got := tr.Snapshot()
	if got.Termination != "completed" || got.AttemptCount != 1 || got.DispatchedAttemptCount != 1 || got.EvidenceConflict {
		t.Fatalf("duplicate terminal inflated counts: %+v", got)
	}
	a.Observe("provider_error", "provider_error", 500)
	if got = tr.Snapshot(); !got.EvidenceConflict || got.Termination != "unknown" {
		t.Fatalf("contradictory terminal hidden: %+v", got)
	}
}

func TestRequestAccountingHistoryBoundRetainsCounters(t *testing.T) {
	tr := accountingFixture()
	for i := 0; i < MaxAttempts+3; i++ {
		sentAttempt(tr, fmt.Sprint(i), i, "").Observe("provider_error", "deadline_unreachable", 503)
	}
	tr.Rejection("deadline_unreachable", true)
	tr.Finish(429, false, false)
	got := tr.Snapshot()
	if !got.AttemptsTruncated || len(got.Attempts) != MaxAttempts || got.AttemptCount != MaxAttempts+3 || got.DispatchedAttemptCount != MaxAttempts+3 || got.DeadlineRefusalCount != MaxAttempts+3 {
		t.Fatalf("history bound lost accurate counters: %+v", got)
	}
	got.Attempts[0].RawReason = "mutated"
	if tr.Snapshot().Attempts[0].RawReason == "mutated" {
		t.Fatal("snapshot aliases live attempt history")
	}
}

func TestRequestAccountingContentIngressIsNotClientEgress(t *testing.T) {
	for _, written := range []bool{false, true} {
		tr := accountingFixture()
		a := sentAttempt(tr, "content-attempt", 0, "")
		a.Observe("content", "", 0)
		a.Observe("committed", "", 0)
		if written {
			tr.ContentWritten()
		}
		a.Observe("provider_error", "provider_error", 500)
		tr.Finish(200, false, false)
		got := tr.Snapshot()
		if !tr.HasContent() || got.ResponseProgress != "content_observed" || got.ContentEgressObserved != written || got.ResponseEgressCompleted || got.Termination != "interrupted" {
			t.Fatalf("content ingress became delivery evidence: written=%t record=%+v", written, got)
		}
	}
}

func TestRequestAccountingSyntheticTerminalIsNotProviderRefusal(t *testing.T) {
	tr := accountingFixture()
	a := sentAttempt(tr, "synthetic-timeout", 0, "")
	a.Observe("route_terminal", "deadline_unreachable", 503)
	tr.Rejection("first_chunk_timeout", false)
	tr.Finish(429, false, false)
	got := tr.Snapshot()
	if got.DeadlineRefusalCount != 0 || got.Attempts[0].ProviderOutcome != "no_terminal" || got.Attempts[0].NormalizedCode != "" {
		t.Fatalf("coordinator terminal invented provider refusal: %+v", got)
	}
}
