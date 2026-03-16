// Reputation tracking for DGInf provider agents.
//
// Each provider accumulates a reputation score based on their operational
// history: job success rate, uptime, attestation challenge pass rate, and
// response time. The composite score is used as a factor in the routing
// score to prefer reliable providers.
//
// Score composition:
//   - 40% job success rate (successful / total jobs)
//   - 30% uptime ratio (uptime / expected uptime)
//   - 20% challenge pass rate (passed / total challenges)
//   - 10% response time factor (faster = higher, capped at 1.0)
//
// New providers start with a score of 0.5 (neutral). The score is always
// bounded to [0.0, 1.0].
package registry

import (
	"time"
)

// Reputation tracks a provider's operational reliability metrics.
type Reputation struct {
	TotalJobs        int
	SuccessfulJobs   int
	FailedJobs       int
	TotalUptime      time.Duration
	LastOnline       time.Time
	AvgResponseTime  time.Duration
	ChallengesPassed int
	ChallengesFailed int

	// totalResponseTime is the accumulated response time for averaging.
	totalResponseTime time.Duration
}

// NewReputation creates a new Reputation with neutral defaults.
func NewReputation() Reputation {
	return Reputation{
		LastOnline: time.Now(),
	}
}

// RecordJobSuccess records a successful job completion and updates stats.
func (r *Reputation) RecordJobSuccess(responseTime time.Duration) {
	r.TotalJobs++
	r.SuccessfulJobs++
	r.totalResponseTime += responseTime
	r.AvgResponseTime = r.totalResponseTime / time.Duration(r.SuccessfulJobs)
}

// RecordJobFailure records a failed job.
func (r *Reputation) RecordJobFailure() {
	r.TotalJobs++
	r.FailedJobs++
}

// RecordUptime adds uptime duration to the provider's record.
func (r *Reputation) RecordUptime(duration time.Duration) {
	r.TotalUptime += duration
	r.LastOnline = time.Now()
}

// RecordChallengePass records a successful attestation challenge.
func (r *Reputation) RecordChallengePass() {
	r.ChallengesPassed++
}

// RecordChallengeFail records a failed attestation challenge.
func (r *Reputation) RecordChallengeFail() {
	r.ChallengesFailed++
}

// Score calculates the composite reputation score.
//
// For new providers (no jobs, no challenges), returns 0.5 (neutral).
// The score is always bounded to [0.0, 1.0].
//
// Components:
//   - 40% job success rate
//   - 30% uptime ratio (uses a 24-hour expected uptime baseline)
//   - 20% challenge pass rate
//   - 10% response time factor (sub-second = 1.0, degrades with latency)
func (r *Reputation) Score() float64 {
	// New providers with no history get a neutral score.
	if r.TotalJobs == 0 && r.ChallengesPassed == 0 && r.ChallengesFailed == 0 {
		return 0.5
	}

	// Job success rate (40%)
	var jobRate float64
	if r.TotalJobs > 0 {
		jobRate = float64(r.SuccessfulJobs) / float64(r.TotalJobs)
	} else {
		jobRate = 0.5 // neutral if no jobs yet
	}

	// Uptime ratio (30%) — using 24-hour expected uptime baseline
	var uptimeRate float64
	expectedUptime := 24 * time.Hour
	if r.TotalUptime > 0 {
		uptimeRate = float64(r.TotalUptime) / float64(expectedUptime)
		if uptimeRate > 1.0 {
			uptimeRate = 1.0
		}
	} else {
		uptimeRate = 0.5 // neutral if no uptime tracked
	}

	// Challenge pass rate (20%)
	var challengeRate float64
	totalChallenges := r.ChallengesPassed + r.ChallengesFailed
	if totalChallenges > 0 {
		challengeRate = float64(r.ChallengesPassed) / float64(totalChallenges)
	} else {
		challengeRate = 0.5 // neutral if no challenges
	}

	// Response time factor (10%) — faster is better
	// Sub-second average = 1.0, degrades linearly up to 10 seconds
	var responseTimeFactor float64
	if r.SuccessfulJobs > 0 && r.AvgResponseTime > 0 {
		avgMs := float64(r.AvgResponseTime) / float64(time.Millisecond)
		if avgMs <= 1000 {
			responseTimeFactor = 1.0
		} else if avgMs >= 10000 {
			responseTimeFactor = 0.0
		} else {
			responseTimeFactor = 1.0 - (avgMs-1000)/9000
		}
	} else {
		responseTimeFactor = 0.5 // neutral if no response time data
	}

	score := 0.4*jobRate + 0.3*uptimeRate + 0.2*challengeRate + 0.1*responseTimeFactor

	// Clamp to [0.0, 1.0]
	if score < 0.0 {
		return 0.0
	}
	if score > 1.0 {
		return 1.0
	}
	return score
}
