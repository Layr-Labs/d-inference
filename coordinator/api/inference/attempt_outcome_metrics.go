package inference

import (
	"time"

	infermetrics "github.com/eigeninference/d-inference/coordinator/internal/inference/metrics"
)

// clientGoneDeadlineBucket is the deadline bucket for a pre-content cancel on
// this dispatch, measured on the request clock (ReceivedAt + deadline).
func (d *dispatchState) clientGoneDeadlineBucket() string {
	if d == nil || d.timing == nil || d.timing.ReceivedAt.IsZero() || d.deadline <= 0 {
		return infermetrics.DeadlineUnknown
	}
	return infermetrics.DeadlineBucket(time.Since(d.timing.ReceivedAt), d.deadline)
}

func (d *dispatchState) recordRequestOutcomeORView(class string) {
	if d == nil {
		return
	}
	d.s.NewMetrics().RecordORView(d.model, class)
}

// emitRouteLatency records the attempt-0 route segment. Called once the
// primary attempt's provider is selected (RoutedAt stamped).
func (d *dispatchState) emitRouteLatency() {
	if d == nil || d.s == nil {
		return
	}
	d.s.NewMetrics().RouteLatency(d.model, d.attempt, d.timing)
}
