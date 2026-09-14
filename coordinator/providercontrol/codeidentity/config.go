package codeidentity

import (
	"math/rand/v2"
	"time"

	"github.com/eigeninference/d-inference/coordinator/providercontrol/trustreuse"
)

// This is a same-process continuity bound, never a new lifetime for an APNs
// proof. Changed process keys and release transitions still need a recent proof.
const codeAttestContinuityGap = 120 * time.Second

func newConfiguredState(cfg Config) *deviceState {
	return &deviceState{
		attested:               make(map[string]proofRecord),
		lastPush:               make(map[string]time.Time),
		lastBudgetClear:        make(map[string]time.Time),
		resumeChallenges:       make(map[string]resumeChallenge),
		outstanding:            make(map[string][]pushChallenge),
		loopGenerations:        make(map[string]uint64),
		loopTokens:             make(map[string]string),
		durableNextPush:        make(map[string]time.Time),
		novelTokenBlockedUntil: make(map[string]time.Time),
		novelPushFloor:         make(map[string]time.Time),
		budgetTokenOrder:       make(map[string][]string),
		reservationLocks:       make(map[string]*reservationLock),
		reuseWindow:            cfg.ReuseWindow,
		backgroundPushCooldown: cfg.BackgroundPushCooldown, // <= 3 pushes/hour/device (APNs background budget)
		alertPushCooldown:      cfg.AlertPushCooldown,      // alert is not background-throttled (Fix 3)
		budgetClearCooldown:    cfg.BudgetClearCooldown,    // a token rotation can reset the budget at most ~3x/hour/device
		retrySpacing:           cfg.RetrySpacing,           // poll/backoff cadence, separate from the budget
		retryJitter:            cfg.RetryJitter,            // de-sync fleet retries -> retryDelay in [15s, 30s)
		challengeValidity:      cfg.ChallengeValidity,
		resumeTimeout:          cfg.ResumeTimeout,
		maxAttempts:            cfg.MaxAttempts,
		now:                    cfg.Now,
		jitter:                 cfg.Jitter,
	}
}

func newDeviceState() *deviceState { return newConfiguredState(DefaultConfig()) }

// defaultJitter returns a uniform random duration in [0, max).
func defaultJitter(max time.Duration) time.Duration {
	if max <= 0 {
		return 0
	}
	return time.Duration(rand.Int64N(int64(max)))
}

// Config is captured during construction. Clock and sender test fixtures must
// not mutate their captured values concurrently with active operations.
type Config struct {
	ReuseWindow            time.Duration
	BackgroundPushCooldown time.Duration
	AlertPushCooldown      time.Duration
	BudgetClearCooldown    time.Duration
	RetrySpacing           time.Duration
	RetryJitter            time.Duration
	ChallengeValidity      time.Duration
	ResumeTimeout          time.Duration
	MaxAttempts            int
	Now                    func() time.Time
	Jitter                 func(time.Duration) time.Duration
}

const ChallengeResponseTimeout = 30 * time.Second
const CodeAttestResponseTimeout = 300 * time.Second

// Device and application evidence retain the same existing skew allowance.
const clockSkewTolerance = trustreuse.ClockSkewTolerance

func DefaultConfig() Config {
	return Config{
		ReuseWindow:            30 * time.Minute,
		BackgroundPushCooldown: 20 * time.Minute,
		AlertPushCooldown:      75 * time.Second,
		BudgetClearCooldown:    20 * time.Minute,
		RetrySpacing:           15 * time.Second,
		RetryJitter:            15 * time.Second,
		ChallengeValidity:      CodeAttestResponseTimeout,
		ResumeTimeout:          ChallengeResponseTimeout,
		MaxAttempts:            3, Now: time.Now, Jitter: defaultJitter,
	}
}
