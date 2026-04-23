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
		r.RecordJobSuccess(500 * time.Millisecond)
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
		r.RecordJobSuccess(500 * time.Millisecond)
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
		r2.RecordJobSuccess(100 * time.Millisecond)
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

	r.RecordJobSuccess(100 * time.Millisecond)
	r.RecordJobSuccess(200 * time.Millisecond)
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
	// Average of 100ms and 200ms = 150ms.
	if r.AvgResponseTime != 150*time.Millisecond {
		t.Errorf("avg_response_time = %v, want 150ms", r.AvgResponseTime)
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
	fast.RecordJobSuccess(100 * time.Millisecond)
	fast.RecordUptime(24 * time.Hour)
	fast.RecordChallengePass()

	slow := NewReputation()
	slow.RecordJobSuccess(9 * time.Second)
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
	r.RecordJobSuccess(500 * time.Millisecond)
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
