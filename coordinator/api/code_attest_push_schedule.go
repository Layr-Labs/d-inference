package api

import "time"

// codeAttestPushSchedule decides when one connection's code-attest loop may
// try to reserve another APNs push. The first maxFast pushes follow the loop's
// ordinary poll cadence (each still admitted by the per-device push budget).
// After that the loop does not give up while the connection is alive: it
// continues on a slow cadence of at most one push per slowInterval, so a
// long-lived connection whose first pushes were dropped (for example a burst
// of reconnects right after a release) recovers without a provider reconnect.
// The schedule is only a local pacing rule; reservePush and the durable
// per-device budget remain the hard rate limit, so the slow cadence can never
// push more often than the budget allows.
type codeAttestPushSchedule struct {
	maxFast      int
	slowInterval time.Duration
	pushes       int
	lastPush     time.Time
	slow         bool
}

func newCodeAttestPushSchedule(t *codeAttestThrottle) codeAttestPushSchedule {
	return codeAttestPushSchedule{
		maxFast:      t.maxAttempts,
		slowInterval: t.slowRetryInterval,
	}
}

// enterSlowIfExhausted switches to the slow cadence once the fast attempts are
// spent. It reports true exactly once, on the transition.
func (p *codeAttestPushSchedule) enterSlowIfExhausted() bool {
	if p.slow || p.pushes < p.maxFast {
		return false
	}
	p.slow = true
	return true
}

// due reports whether the loop may try to reserve a push at now.
func (p *codeAttestPushSchedule) due(now time.Time) bool {
	return !p.slow || !now.Before(p.lastPush.Add(p.slowInterval))
}

// recordPush notes a reserved push (sent or not: the budget was spent).
func (p *codeAttestPushSchedule) recordPush(now time.Time) {
	p.pushes++
	p.lastPush = now
}
