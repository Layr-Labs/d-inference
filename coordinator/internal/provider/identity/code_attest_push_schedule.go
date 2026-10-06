package identity

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
type PushSchedule struct {
	maxFast      int
	slowInterval time.Duration
	Pushes       int
	lastPush     time.Time
	Slow         bool
}

func NewCodeAttestPushSchedule(t *Throttle) PushSchedule {
	return PushSchedule{
		maxFast:      t.MaxAttempts,
		slowInterval: t.SlowRetryInterval,
	}
}

// enterSlowIfExhausted switches to the slow cadence once the fast attempts are
// spent. It reports true exactly once, on the transition.
func (p *PushSchedule) EnterSlowIfExhausted() bool {
	if p.Slow || p.Pushes < p.maxFast {
		return false
	}
	p.Slow = true
	return true
}

// due reports whether the loop may try to reserve a push at now.
func (p *PushSchedule) Due(now time.Time) bool {
	return !p.Slow || !now.Before(p.lastPush.Add(p.slowInterval))
}

// recordPush notes a reserved push (sent or not: the budget was spent).
func (p *PushSchedule) RecordPush(now time.Time) {
	p.Pushes++
	p.lastPush = now
}
