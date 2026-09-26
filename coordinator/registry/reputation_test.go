package registry

import (
	"testing"
	"time"
)

func TestReputationJobSuccessStats(t *testing.T) {
	r := NewReputation()

	r.RecordJobSuccess()
	r.RecordLatency(100 * time.Millisecond)
	r.RecordJobSuccess()
	r.RecordLatency(200 * time.Millisecond)
	r.RecordJobFailure()

	if r.TotalJobs != 3 {
		t.Errorf("total_jobs = %d, want 3", r.TotalJobs)
	}
	if r.SuccessfulJobs != 2 {
		t.Errorf("successful_jobs = %d, want 2", r.SuccessfulJobs)
	}
	if r.FailedJobs != 1 {
		t.Errorf("failed_jobs = %d, want 1", r.FailedJobs)
	}
	// EWMA (alpha=0.2): first sample 100ms seeds the average; second sample
	// 200ms gives 100*0.8 + 200*0.2 = 120ms.
	if r.AvgResponseTime != 120*time.Millisecond {
		t.Errorf("avg_response_time = %v, want 120ms (EWMA)", r.AvgResponseTime)
	}
}

func TestReputationUptimeTracking(t *testing.T) {
	r := NewReputation()

	r.RecordUptime(12 * time.Hour)
	if r.TotalUptime != 12*time.Hour {
		t.Errorf("total_uptime = %v, want 12h", r.TotalUptime)
	}

	r.RecordUptime(12 * time.Hour)
	if r.TotalUptime != 24*time.Hour {
		t.Errorf("total_uptime = %v, want 24h", r.TotalUptime)
	}
}

func TestReputationChallengeTracking(t *testing.T) {
	r := NewReputation()

	r.RecordChallengePass()
	r.RecordChallengePass()
	r.RecordChallengeFail()

	if r.ChallengesPassed != 2 {
		t.Errorf("challenges_passed = %d, want 2", r.ChallengesPassed)
	}
	if r.ChallengesFailed != 1 {
		t.Errorf("challenges_failed = %d, want 1", r.ChallengesFailed)
	}
}

func TestRecordLatencyEWMA(t *testing.T) {
	r := NewReputation()

	// First sample seeds the average directly.
	r.RecordLatency(100 * time.Millisecond)
	if r.AvgResponseTime != 100*time.Millisecond {
		t.Fatalf("after seed: avg = %v, want 100ms", r.AvgResponseTime)
	}

	// Second sample: 100*0.8 + 200*0.2 = 120ms.
	r.RecordLatency(200 * time.Millisecond)
	if r.AvgResponseTime != 120*time.Millisecond {
		t.Fatalf("after second sample: avg = %v, want 120ms", r.AvgResponseTime)
	}

	// Zero and negative samples are no-ops (a missing FirstChunkAt must not
	// drag the average toward zero).
	r.RecordLatency(0)
	r.RecordLatency(-5 * time.Millisecond)
	if r.AvgResponseTime != 120*time.Millisecond {
		t.Fatalf("after zero/negative samples: avg = %v, want unchanged 120ms", r.AvgResponseTime)
	}
}

// TestRecordJobSuccessDoesNotSetLatency verifies successes do not fabricate latency.
func TestRecordJobSuccessDoesNotSetLatency(t *testing.T) {
	r := NewReputation()
	for range 5 {
		r.RecordJobSuccess()
	}
	if r.SuccessfulJobs != 5 {
		t.Errorf("successful_jobs = %d, want 5", r.SuccessfulJobs)
	}
	if r.AvgResponseTime != 0 {
		t.Errorf("avg_response_time = %v, want 0 (job success must not fabricate latency)", r.AvgResponseTime)
	}
}
