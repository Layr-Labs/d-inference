package state

import (
	"time"
)

// ContinuityGap bounds same-process coverage, not the age of an APNs proof.
const ContinuityGap = 120 * time.Second

type Policy struct {
	ReuseWindow time.Duration
	// Push budget (the hard background-push rate-limit backstop) is mode-aware:
	// allowPush picks the cooldown by delivery mode.
	BackgroundPushCooldown time.Duration
	AlertPushCooldown      time.Duration
	// budgetClearCooldown is the minimum spacing between token-rotation budget
	// resets per device (clearPushBudget). A provider can put any string in the
	// heartbeat APNs-token field on every heartbeat; without this floor each
	// "rotation" would reset the push budget and force an immediate push, letting a
	// misbehaving provider spam APNs (and coordinator work) far beyond Apple's
	// per-device budget. A GENUINE rotation is rare, so it still clears promptly; a
	// flood is throttled back to the normal cooldown.
	BudgetClearCooldown time.Duration
	// retrySpacing is the loop's poll/backoff cadence, decoupled from the push
	// budget; retryJitter de-synchronises a fleet-wide reconnect so pushes don't
	// thunder against the per-device budget.
	RetrySpacing time.Duration
	RetryJitter  time.Duration
	// challengeValidity bounds how long a pushed nonce is accepted by the read-loop
	// delivery path. Kept consistent with the APNs apns-expiration window (W5b
	// Fix 5): a reply is accepted for as long as the push could still have been
	// delivered.
	ChallengeValidity time.Duration
	ResumeTimeout     time.Duration
	// maxAttempts is the number of pushes on the fast retry cadence. After
	// them a still-live, still-unattested connection keeps retrying on the
	// slow cadence: at most one push per slowRetryInterval, each still
	// admitted by reservePush and the durable per-device budget.
	MaxAttempts       int
	SlowRetryInterval time.Duration
	Now               func() time.Time
	Jitter            func(max time.Duration) time.Duration
}

func (p *Policy) PushCooldown(alert bool) time.Duration {
	if alert {
		return p.AlertPushCooldown
	}
	return p.BackgroundPushCooldown
}

// AllowsPush is the local cooldown rule; durable CAS and loop ownership still
// have to admit the reservation before any push may be sent.
func (p *Policy) AllowsPush(last time.Time, exists bool, now time.Time, alert bool) bool {
	return !exists || now.Sub(last) >= p.PushCooldown(alert)
}

func NewPolicy(ChallengeValidity, ResumeTimeout time.Duration) *Policy {
	return &Policy{
		ReuseWindow:            30 * time.Minute,
		BackgroundPushCooldown: 20 * time.Minute,
		AlertPushCooldown:      75 * time.Second,
		BudgetClearCooldown:    20 * time.Minute,
		RetrySpacing:           15 * time.Second,
		RetryJitter:            15 * time.Second,
		ChallengeValidity:      ChallengeValidity,
		ResumeTimeout:          ResumeTimeout,
		MaxAttempts:            3,
		SlowRetryInterval:      60 * time.Minute,
		Now:                    time.Now,
		Jitter:                 defaultJitter,
	}
}
