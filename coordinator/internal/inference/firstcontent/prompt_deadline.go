package firstcontent

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// DurationWithinContext preserves an earlier caller cutoff in scheduler and
// provider budgets. An already expired cutoff remains enabled, never exempt.
func DurationWithinContext(ctx context.Context, received time.Time, duration time.Duration) time.Duration {
	if duration <= 0 || received.IsZero() {
		return duration
	}
	if cutoff, ok := ctx.Deadline(); ok && cutoff.Before(received.Add(duration)) {
		return max(time.Nanosecond, cutoff.Sub(received))
	}
	return duration
}

// SetPromptWorkDeadlines carries both ingress-anchored token terms until a
// reservation qualifies one against the selected provider's renderer.
func SetPromptWorkDeadlines(pr *registry.PendingRequest, received time.Time, fallback, qualified time.Duration) {
	if pr == nil || received.IsZero() || fallback <= 0 {
		return
	}
	pr.FirstContentFallbackDeadline = received.Add(fallback)
	if qualified > 0 && qualified != fallback {
		pr.FirstContentQualifiedDeadline = received.Add(qualified)
	}
	pr.FirstContentDeadline = pr.FirstContentDeadlineEnvelope()
}

// FirstTokenWriteContextForPending uses the selected attempt's immutable
// cutoff. A zero logical deadline still preserves the account exemption.
func FirstTokenWriteContextForPending(ctx context.Context, received time.Time, fallback time.Duration, pr *registry.PendingRequest) (context.Context, context.CancelFunc) {
	if fallback > 0 && pr != nil && !pr.FirstContentDeadline.IsZero() {
		return context.WithDeadline(ctx, pr.FirstContentDeadline)
	}
	return FirstTokenWriteContext(ctx, received, fallback)
}
