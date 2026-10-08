package firstcontent

import "time"

// Clock keeps the original receive instant across queueing, dispatch, retries
// and media work. A zero deadline disables content timers, not hedge scheduling.
type Clock struct {
	receivedAt    time.Time
	deadline      time.Duration
	speculativeAt time.Duration
	cutoff        time.Time
}

func NewClock(receivedAt time.Time, deadline, speculativeAt time.Duration) Clock {
	return Clock{receivedAt: receivedAt, deadline: deadline, speculativeAt: speculativeAt}
}

func (c Clock) Remaining() (time.Duration, bool) {
	if c.deadline > 0 && !c.cutoff.IsZero() {
		return max(0, time.Until(c.cutoff)), true
	}
	if c.deadline <= 0 || c.receivedAt.IsZero() {
		return 0, false
	}
	return FirstTokenRemainingSince(c.receivedAt, c.deadline), true
}

func (c Clock) Wait(relativeFallback time.Duration) time.Duration {
	if c.deadline <= 0 {
		return 0
	}
	if remaining, ok := c.Remaining(); ok {
		return remaining
	}
	if relativeFallback < 0 {
		return 0
	}
	return relativeFallback
}

func (c Clock) Expired() bool {
	remaining, ok := c.Remaining()
	return ok && remaining == 0
}

func (c Clock) CanExtendPreamble() bool { return c.Wait(PreambleContentTimeout) > 0 }

func (c Clock) SpeculativeWait() time.Duration {
	if c.deadline > 0 && !c.cutoff.IsZero() {
		if c.receivedAt.IsZero() {
			return min(max(0, c.speculativeAt), max(0, time.Until(c.cutoff)))
		}
		return min(max(0, time.Until(c.receivedAt.Add(c.speculativeAt))), max(0, time.Until(c.cutoff)))
	}
	remaining, ok := c.Remaining()
	if !ok {
		if c.speculativeAt < 0 {
			return 0
		}
		return c.speculativeAt
	}
	if remaining <= 0 {
		return 0
	}
	elapsed := c.deadline - remaining
	if elapsed < 0 {
		elapsed = 0
	}
	specWait := c.speculativeAt - elapsed
	if specWait < 0 {
		specWait = 0
	}
	if specWait > remaining {
		specWait = remaining
	}
	return specWait
}

// Timer has a nil select arm for SLA-exempt requests and allocates no timer.
type Timer struct {
	C     <-chan time.Time
	timer *time.Timer
}

func (c Clock) Timer(wait time.Duration) Timer {
	if c.deadline <= 0 {
		return Timer{}
	}
	timer := time.NewTimer(wait)
	return Timer{C: timer.C, timer: timer}
}

func (t Timer) Stop() bool { return t.timer != nil && t.timer.Stop() }
