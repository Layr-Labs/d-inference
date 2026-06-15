package registry

import (
	"testing"
	"time"
)

func TestNewReputationScore(t *testing.T) {
	r := NewReputation()
	score := r.Score()
	if score != 0.5 {
		t.Errorf("new reputation score = %f, want 0.5", score)
	}
}

func TestReputationSuccessfulJobsIncreaseScore(t *testing.T) {
	r := NewReputation()
	initialScore := r.Score()

	// Record several successful jobs with fast response times.
	for range 10 {
		r.RecordJobSuccess()
		r.RecordLatency(500 * time.Millisecond)
	}
	r.RecordUptime(24 * time.Hour)
	r.RecordChallengePass()

	score := r.Score()
	if score <= initialScore {
		t.Errorf("score after successful jobs = %f, should be > initial %f", score, initialScore)
	}
}

func TestReputationFailedJobsDecreaseScore(t *testing.T) {
	r := NewReputation()

	// Record some successes first to establish a baseline.
	for range 5 {
		r.RecordJobSuccess()
		r.RecordLatency(500 * time.Millisecond)
	}
	r.RecordUptime(24 * time.Hour)
	scoreAfterSuccess := r.Score()

	// Now record many failures.
	for range 20 {
		r.RecordJobFailure()
	}

	score := r.Score()
	if score >= scoreAfterSuccess {
		t.Errorf("score after failures = %f, should be < %f", score, scoreAfterSuccess)
	}
}

func TestReputationScoreBounded(t *testing.T) {
	r := NewReputation()

	// All failures — score should not go below 0.0.
	for range 100 {
		r.RecordJobFailure()
	}
	for range 100 {
		r.RecordChallengeFail()
	}

	score := r.Score()
	if score < 0.0 {
		t.Errorf("score = %f, should not be below 0.0", score)
	}

	// Reset and do all successes — score should not exceed 1.0.
	r2 := NewReputation()
	for range 100 {
		r2.RecordJobSuccess()
		r2.RecordLatency(100 * time.Millisecond)
	}
	r2.RecordUptime(48 * time.Hour) // more than expected
	for range 100 {
		r2.RecordChallengePass()
	}

	score2 := r2.Score()
	if score2 > 1.0 {
		t.Errorf("score = %f, should not exceed 1.0", score2)
	}
}

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

func TestReputationSlowResponseTimeLowersScore(t *testing.T) {
	fast := NewReputation()
	fast.RecordJobSuccess()
	fast.RecordLatency(100 * time.Millisecond)
	fast.RecordUptime(24 * time.Hour)
	fast.RecordChallengePass()

	slow := NewReputation()
	slow.RecordJobSuccess()
	slow.RecordLatency(9 * time.Second)
	slow.RecordUptime(24 * time.Hour)
	slow.RecordChallengePass()

	fastScore := fast.Score()
	slowScore := slow.Score()

	if slowScore >= fastScore {
		t.Errorf("slow score (%f) should be less than fast score (%f)", slowScore, fastScore)
	}
}

func TestReputationCompositeWeights(t *testing.T) {
	// Test with only job success rate active (other components neutral).
	r := NewReputation()
	r.RecordJobSuccess()
	r.RecordLatency(500 * time.Millisecond)
	// No uptime, no challenges — those use neutral 0.5.
	// Job rate = 1.0, uptime = 0.5, challenge = 0.5, response = ~1.0.
	// Score = 0.4*1.0 + 0.3*0.5 + 0.2*0.5 + 0.1*1.0 = 0.4 + 0.15 + 0.1 + 0.1 = 0.75.
	score := r.Score()
	if score < 0.7 || score > 0.8 {
		t.Errorf("score with only successful jobs = %f, expected ~0.75", score)
	}
}

func TestReputationAllFailures(t *testing.T) {
	r := NewReputation()
	for range 10 {
		r.RecordJobFailure()
	}
	for range 10 {
		r.RecordChallengeFail()
	}
	// Job rate = 0, challenge rate = 0, uptime = 0.5, response = 0.5.
	// Score = 0.4*0 + 0.3*0.5 + 0.2*0 + 0.1*0.5 = 0 + 0.15 + 0 + 0.05 = 0.2.
	score := r.Score()
	if score < 0.15 || score > 0.25 {
		t.Errorf("score with all failures = %f, expected ~0.2", score)
	}
}

// TestRecordLatencyEWMA verifies AvgResponseTime is an exponential moving
// average of real TTFT samples: the first sample seeds it, subsequent samples
// blend at alpha=0.2, and non-positive samples are ignored.
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

// TestReputationFullUptimeExceedsLegacyCap is the regression: a flawless
// always-online provider must beat the old 0.85 cap once uptime accumulates.
// Before the fix RecordUptime was never called in prod, pinning uptimeRate to
// the neutral 0.5 and capping a perfect score at 0.4+0.15+0.2+0.1 = 0.85.
func TestReputationFullUptimeExceedsLegacyCap(t *testing.T) {
	r := NewReputation()
	r.RecordUptime(24 * time.Hour) // full expected-uptime baseline -> uptimeRate 1.0
	for range 10 {
		r.RecordJobSuccess()
		r.RecordLatency(500 * time.Millisecond)
	}
	r.RecordChallengePass()

	score := r.Score()
	if score <= 0.85 {
		t.Errorf("score = %f, want > 0.85 (legacy cap must be lifted by real uptime)", score)
	}
	// Perfect record -> 0.4*1 + 0.3*1 + 0.2*1 + 0.1*1 = 1.0.
	if score < 0.99 {
		t.Errorf("score = %f, want ~1.0 for a flawless always-online provider", score)
	}
}

// TestReputationNoUptimeStillNeutral pins the unchanged no-data behavior: a
// provider with a perfect job/challenge record but ZERO uptime still maxes at
// the old 0.85 (the uptime component falls back to the neutral 0.5). This guards
// against accidentally changing the else-branch when wiring the uptime credit.
func TestReputationNoUptimeStillNeutral(t *testing.T) {
	r := NewReputation()
	for range 10 {
		r.RecordJobSuccess()
		r.RecordLatency(500 * time.Millisecond)
	}
	r.RecordChallengePass()
	// No RecordUptime — uptimeRate uses neutral 0.5.
	// 0.4*1 + 0.3*0.5 + 0.2*1 + 0.1*1 = 0.85.
	score := r.Score()
	if score < 0.84 || score > 0.86 {
		t.Errorf("score = %f, want ~0.85 (neutral uptime path preserved)", score)
	}
}

// TestReputationRampUptimeNeverBelowLegacyCap is the ramp-down
// regression flagged in review: once Heartbeat starts crediting uptime, a
// freshly-connected (or freshly-restarted, since prod uses the in-memory store
// that resets TotalUptime) provider has a TINY TotalUptime. Without the neutral
// floor, uptimeRate = 30s/24h ≈ 0.0003 would crater a perfect provider from
// 0.85 to ~0.70 for ~12h and deroute it. The floor must hold the score at or
// above the legacy 0.85 throughout the ramp, only ever adding above it.
func TestReputationRampUptimeNeverBelowLegacyCap(t *testing.T) {
	for _, up := range []time.Duration{
		1 * time.Second, 30 * time.Second, 1 * time.Minute,
		30 * time.Minute, 6 * time.Hour, 11 * time.Hour, 13 * time.Hour, 24 * time.Hour,
	} {
		r := NewReputation()
		r.RecordUptime(up)
		for range 10 {
			r.RecordJobSuccess()
			r.RecordLatency(500 * time.Millisecond)
		}
		r.RecordChallengePass()
		if score := r.Score(); score < 0.85 {
			t.Errorf("uptime=%s: score = %f, want >= 0.85 (ramp must never dip below the legacy cap)", up, score)
		}
	}
}

// TestRecordJobSuccessDoesNotSetLatency is the regression guard:
// recording job successes WITHOUT a latency sample must leave AvgResponseTime
// at zero, proving the old synthetic completionTokens*10ms coupling is gone.
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
