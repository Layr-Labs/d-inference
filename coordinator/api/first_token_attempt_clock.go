package api

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// A selected attempt owns its immutable cutoff; the logical request's
// preselection envelope is only a fallback for legacy relative fixtures.
func firstTokenWriteContextForPending(ctx context.Context, receivedAt time.Time, fallback time.Duration, pr *registry.PendingRequest) (context.Context, context.CancelFunc) {
	if fallback > 0 && pr != nil && !pr.FirstContentDeadline.IsZero() {
		return context.WithDeadline(ctx, pr.FirstContentDeadline)
	}
	return firstTokenWriteContext(ctx, receivedAt, fallback)
}

// firstTokenRemainingFor never substitutes the preselection envelope for a
// bound provider clock. Pass the actual survivor, which may differ from d.pr.
func (d *dispatchState) firstTokenRemainingFor(pr *registry.PendingRequest) (remaining time.Duration, ok bool) {
	if d == nil || d.deadline <= 0 {
		return 0, false
	}
	if pr != nil && !pr.FirstContentDeadline.IsZero() {
		return max(0, time.Until(pr.FirstContentDeadline)), true
	}
	return d.firstTokenRemaining()
}

func (d *dispatchState) firstTokenWaitFor(pr *registry.PendingRequest, relativeFallback time.Duration) time.Duration {
	if remaining, ok := d.firstTokenRemainingFor(pr); ok {
		return remaining
	}
	return d.firstTokenWait(relativeFallback)
}

func (d *dispatchState) canExtendPreambleLivenessFor(pr *registry.PendingRequest) bool {
	return d.firstTokenWaitFor(pr, preambleContentTimeout) > 0
}

func (d *dispatchState) firstContentReceivedAt(pr *registry.PendingRequest) time.Time {
	if pr != nil {
		if received := timingReceivedAt(pr.Timing); !received.IsZero() {
			return received
		}
	}
	return timingReceivedAt(d.timing)
}

// A shorter bound interval must still have a halfway hedge opportunity.
// Earlier model policy and quote advances remain earlier absolute points.
func (d *dispatchState) firstTokenSpeculativeAtFor(pr *registry.PendingRequest) time.Duration {
	if d.deadline <= 0 || pr == nil || pr.FirstContentDeadline.IsZero() {
		return d.speculativeAt
	}
	received := d.firstContentReceivedAt(pr)
	if received.IsZero() {
		return d.speculativeAt
	}
	return min(d.speculativeAt, max(0, pr.FirstContentDeadline.Sub(received))/2)
}

func (d *dispatchState) firstTokenSpeculativeWaitFor(pr *registry.PendingRequest) time.Duration {
	remaining, ok := d.firstTokenRemainingFor(pr)
	if !ok {
		return d.firstTokenSpeculativeWait()
	}
	received := d.firstContentReceivedAt(pr)
	if received.IsZero() {
		return min(d.firstTokenSpeculativeWait(), remaining)
	}
	return min(max(0, time.Until(received.Add(d.firstTokenSpeculativeAtFor(pr)))), remaining)
}

// The first race timer visits the earlier bound cutoff. Its expiration does
// not spend a different renderer's independently qualified remaining budget.
func (d *dispatchState) firstContentRaceWait(primary, backup *registry.PendingRequest, fallback time.Duration) time.Duration {
	return min(d.firstTokenWaitFor(primary, fallback), d.firstTokenWaitFor(backup, fallback))
}

func (d *dispatchState) boundFirstContentExpired(pr *registry.PendingRequest, now time.Time) bool {
	return d.deadline > 0 && pr != nil && !pr.FirstContentDeadline.IsZero() && !now.Before(pr.FirstContentDeadline)
}

// A timeout can defer to on-time ingress while its content classification is
// unfinished. When that event proves to be boilerplate, revisit the expired
// absolute cutoff. Relative timers never gain a new window from this helper.
func (d *dispatchState) rearmExpiredFirstContentTimer(timer *firstContentTimer, pr *registry.PendingRequest) {
	if d.boundFirstContentExpired(pr, time.Now()) {
		timer.Stop()
		*timer = d.newFirstContentTimer(d.firstTokenWaitFor(pr, 0))
	}
}

func (d *dispatchState) rearmExpiredFirstContentRaceTimer(timer *firstContentTimer, primary, backup *registry.PendingRequest) {
	now := time.Now()
	if d.boundFirstContentExpired(primary, now) || d.boundFirstContentExpired(backup, now) {
		timer.Stop()
		*timer = d.newFirstContentTimer(d.firstContentRaceWait(primary, backup, 0))
	}
}

func (d *dispatchState) firstContentDurationFor(pr *registry.PendingRequest, fallback time.Duration) time.Duration {
	if pr == nil || pr.FirstContentDeadline.IsZero() {
		return fallback
	}
	received := d.firstContentReceivedAt(pr)
	if received.IsZero() {
		return fallback
	}
	return max(time.Nanosecond, pr.FirstContentDeadline.Sub(received))
}
