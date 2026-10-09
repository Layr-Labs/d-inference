package firstcontent

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// ForPending binds a wait to the reserved provider's absolute cutoff. An SLA
// exemption cannot be enabled by stale pending metadata.
func (c Clock) ForPending(pr *registry.PendingRequest) Clock {
	if c.deadline <= 0 || pr == nil || pr.FirstContentDeadline.IsZero() {
		return c
	}
	c.cutoff = pr.FirstContentDeadline
	if received := TimingReceivedAt(pr.Timing); !received.IsZero() {
		c.receivedAt = received
	}
	if !c.receivedAt.IsZero() {
		c.speculativeAt = min(c.speculativeAt, max(0, c.cutoff.Sub(c.receivedAt))/2)
	}
	return c
}

func (c Clock) BoundExpired() bool {
	return c.deadline > 0 && !c.cutoff.IsZero() && !time.Now().Before(c.cutoff)
}

// Duration attributes a timeout to this renderer's interval, not another
// candidate's larger preselection envelope.
func (c Clock) Duration(fallback time.Duration) time.Duration {
	if c.cutoff.IsZero() || c.receivedAt.IsZero() {
		return fallback
	}
	return max(time.Nanosecond, c.cutoff.Sub(c.receivedAt))
}

// RearmExpired revisits an expired cutoff after on-time ingress classified as
// boilerplate. It does not grant a fresh relative window.
func (c Clock) RearmExpired(timer *Timer) {
	if c.BoundExpired() {
		timer.Stop()
		*timer = c.Timer(c.Wait(0))
	}
}

func (c Clock) RaceWait(primary, backup *registry.PendingRequest, fallback time.Duration) time.Duration {
	return min(c.ForPending(primary).Wait(fallback), c.ForPending(backup).Wait(fallback))
}

func (c Clock) RearmExpiredRace(timer *Timer, primary, backup *registry.PendingRequest) {
	if c.ForPending(primary).BoundExpired() || c.ForPending(backup).BoundExpired() {
		timer.Stop()
		*timer = c.Timer(c.RaceWait(primary, backup, 0))
	}
}
