package registry

import (
	"testing"
	"time"
)

func TestRecordJobSuccessUpdatesReputation(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)

	reg.RecordJobSuccess("p1", 500*time.Millisecond)
	reg.RecordJobSuccess("p1", 500*time.Millisecond)

	if p.Reputation.SuccessfulJobs != 2 {
		t.Errorf("successful_jobs = %d, want 2", p.Reputation.SuccessfulJobs)
	}
	if p.Reputation.TotalJobs != 2 {
		t.Errorf("total_jobs = %d, want 2", p.Reputation.TotalJobs)
	}
	// Both calls fed a 500ms TTFT: seed 500ms then EWMA stays 500ms.
	if p.Reputation.AvgResponseTime != 500*time.Millisecond {
		t.Errorf("avg_response_time = %v, want 500ms", p.Reputation.AvgResponseTime)
	}
}

// TestRecordJobSuccessLatencyEWMA exercises the Registry wrapper end-to-end: the
// real TTFT passed to RecordJobSuccess is folded into the provider's
// AvgResponseTime EWMA, and a non-positive TTFT records the job without
// touching latency.
func TestRecordJobSuccessLatencyEWMA(t *testing.T) {
	reg := New(testLogger())
	p := reg.Register("p1", nil, testRegisterMessage())

	reg.RecordJobSuccess("p1", 100*time.Millisecond) // seed
	if got := p.Reputation.AvgResponseTime; got != 100*time.Millisecond {
		t.Fatalf("after seed: avg = %v, want 100ms", got)
	}
	reg.RecordJobSuccess("p1", 200*time.Millisecond) // 100*0.8 + 200*0.2 = 120ms
	if got := p.Reputation.AvgResponseTime; got != 120*time.Millisecond {
		t.Fatalf("after EWMA: avg = %v, want 120ms", got)
	}

	// A zero TTFT (no first-chunk timestamp) still counts the job but leaves
	// the latency average unchanged.
	reg.RecordJobSuccess("p1", 0)
	if got := p.Reputation.AvgResponseTime; got != 120*time.Millisecond {
		t.Fatalf("after zero ttft: avg = %v, want unchanged 120ms", got)
	}
	if p.Reputation.SuccessfulJobs != 3 {
		t.Errorf("successful_jobs = %d, want 3", p.Reputation.SuccessfulJobs)
	}
}

func TestRecordJobFailureUpdatesReputation(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)

	reg.RecordJobFailure("p1")

	if p.Reputation.FailedJobs != 1 {
		t.Errorf("failed_jobs = %d, want 1", p.Reputation.FailedJobs)
	}
	if p.Reputation.TotalJobs != 1 {
		t.Errorf("total_jobs = %d, want 1", p.Reputation.TotalJobs)
	}
}
