// Reputation tracking for Darkbloom provider agents.
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
// The response time factor grades AvgResponseTime, an EWMA of a per-request
// responsiveness sample (time to first content, with the prompt-size-dependent
// prefill removed) fed via RecordLatency — NOT a synthetic function of answer
// length, and not penalized by how large a prompt the provider happened to serve.
//
// New providers start with a score of 0.5 (neutral). The score is always
// bounded to [0.0, 1.0].
package registry

import (
	"time"
)

// ttftEWMAAlpha is the weight given to each new TTFT sample in the exponential
// moving average held by AvgResponseTime. 0.2 means a fresh sample contributes
// 20% and the prior average 80%, so the value is recency-weighted but smooth
// across transient spikes.
const ttftEWMAAlpha = 0.2

// Reputation tracks a provider's operational reliability metrics.
type Reputation struct {
	TotalJobs      int
	SuccessfulJobs int
	FailedJobs     int
	TotalUptime    time.Duration
	LastOnline     time.Time
	// AvgResponseTime is an EWMA of a per-request responsiveness sample (time to
	// first content minus the prompt-size prefill). It backs the stable wire field
	// avg_response_time_ms. Updated by RecordLatency; decoupled from job counting
	// (RecordJobSuccess).
	AvgResponseTime  time.Duration
	ChallengesPassed int
	ChallengesFailed int
}

// NewReputation creates a new Reputation with neutral defaults.
func NewReputation() Reputation {
	return Reputation{
		LastOnline: time.Now(),
	}
}

// RecordJobSuccess records a successful job completion.
//
// Latency is recorded separately via RecordLatency: job success and TTFT are
// orthogonal so a completion with no first-chunk timestamp still counts as a
// success without poisoning the latency EWMA.
func (r *Reputation) RecordJobSuccess() {
	r.TotalJobs++
	r.SuccessfulJobs++
}

// RecordLatency folds a per-request responsiveness sample into the
// AvgResponseTime EWMA. Non-positive samples (e.g. a completion with no
// first-content timestamp) are ignored so a missing timestamp cannot drag the
// average toward zero. The first valid sample seeds the average directly.
func (r *Reputation) RecordLatency(ttft time.Duration) {
	if ttft <= 0 {
		return
	}
	if r.AvgResponseTime == 0 {
		r.AvgResponseTime = ttft
		return
	}
	r.AvgResponseTime = time.Duration(float64(r.AvgResponseTime)*(1-ttftEWMAAlpha) + float64(ttft)*ttftEWMAAlpha)
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
//   - 10% response time factor (responsiveness EWMA; sub-second = 1.0, degrades with latency)
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

	// Uptime ratio (30%) — 24-hour expected-uptime baseline, FLOORED at the
	// neutral 0.5 during ramp-up. Uptime only ever *adds* above the legacy
	// baseline: it never pulls a provider below the score it had when uptime
	// was untracked (== 0.5). Without this floor a freshly-connected or
	// recently-restarted provider (small TotalUptime → tiny ratio) would score
	// BELOW the old 0.85 cap for ~12h and be derouted — and because prod uses
	// the in-memory store, TotalUptime resets on every coordinator restart /
	// provider reconnect, so that penalty would re-apply fleet-wide.
	uptimeRate := 0.5
	expectedUptime := 24 * time.Hour
	if r.TotalUptime > 0 {
		if ratio := float64(r.TotalUptime) / float64(expectedUptime); ratio > uptimeRate {
			uptimeRate = ratio
		}
		if uptimeRate > 1.0 {
			uptimeRate = 1.0
		}
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
