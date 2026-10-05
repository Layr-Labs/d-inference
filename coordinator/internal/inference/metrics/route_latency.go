package metrics

import (
	"math"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

const RouteLatencyMetric = "routing.route_latency_ms"

// RouteLatency emits only direct attempt-zero selections. Queue waiting and
// remote media fetch time do not measure CPU routing work.
func (s *Reporter) RouteLatency(model string, attempt int, t *registry.RequestTiming) {
	if s == nil || s.Observation.Datadog() == nil || attempt != 0 || t == nil {
		return
	}
	if !t.QueuedAt.IsZero() || t.RoutedAt.IsZero() {
		return
	}
	anchor := t.ReservedAt
	if !t.MediaFetchedAt.IsZero() {
		anchor = t.MediaFetchedAt
	}
	if anchor.IsZero() || t.RoutedAt.Before(anchor) {
		return
	}
	ms := float64(t.RoutedAt.Sub(anchor)) / float64(time.Millisecond)
	if ms < 0 || math.IsNaN(ms) || math.IsInf(ms, 0) {
		return
	}
	s.Observation.Histogram(RouteLatencyMetric, ms, []string{"model:" + model})
}
