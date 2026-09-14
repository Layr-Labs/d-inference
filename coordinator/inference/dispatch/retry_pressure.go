package dispatch

import (
	"math"
	"time"
)

// noteAttempt0RouteLatency folds one attempt-0 route latency (ReceivedAt →
// RoutedAt) into the distress EWMA. Called from dispatchWithReserver where
// RoutedAt is stamped; negative samples (clock skew) are dropped.
func (s *Controller) noteAttempt0RouteLatency(d time.Duration) {
	ms := float64(d) / float64(time.Millisecond)
	if ms < 0 {
		return
	}
	s.routeLatencyMu.Lock()
	if s.routeLatencyEWMAMs == 0 {
		s.routeLatencyEWMAMs = ms
	} else {
		s.routeLatencyEWMAMs = routeLatencyEWMAAlpha*ms +
			(1-routeLatencyEWMAAlpha)*s.routeLatencyEWMAMs
	}
	s.routeLatencyMu.Unlock()
}

// attempt0RouteEWMAMs reads the current attempt-0 route-latency EWMA (ms).
func (s *Controller) attempt0RouteEWMAMs() float64 {
	s.routeLatencyMu.Lock()
	defer s.routeLatencyMu.Unlock()
	return s.routeLatencyEWMAMs
}

// estimateRetryAfter returns a suggested wait time in seconds before retrying
// a request for the given model. Based on queue depth as a rough proxy for
// fleet backlog. OpenRouter uses the Retry-After header to schedule retries.
//
// Distress scaling (2026-09-01 congestion collapse): queue depth alone was a
// LIAR under CPU saturation — the queue was empty (nothing could even reach
// it), so every 429 carried "Retry-After: 2" and upstream obligingly hammered
// the coordinator every 2s, sustaining the death loop. When the attempt-0
// route-latency EWMA shows routing itself is degraded (> 1s), the answer
// scales with the observed degradation — max(base, ceil(EWMA seconds)×5),
// capped at 60s — so upstream backoff actually relieves pressure. Queue-depth
// behavior is unchanged while routing is healthy.
func (s *Controller) EstimateRetryAfter(model string) int {
	estimate := 2 // Light load, retry soon
	if queueDepth := s.deps.Registry().Queue().QueueSize(model); queueDepth > 0 {
		// Rough estimate: each queued request takes ~3 seconds to drain.
		estimate = queueDepth * 3
		if estimate < 2 {
			estimate = 2
		}
		if estimate > 30 {
			estimate = 30
		}
	}
	if ewmaMs := s.attempt0RouteEWMAMs(); ewmaMs > degradedRouteEWMAThresholdMs {
		scaled := int(math.Ceil(ewmaMs/1000)) * 5
		if scaled > maxDistressRetryAfter {
			scaled = maxDistressRetryAfter
		}
		if scaled > estimate {
			estimate = scaled
		}
	}
	return estimate
}

// routeLatencyEWMAAlpha weights the newest attempt-0 route-latency sample in
// the distress EWMA: ~10 healthy requests pull a degraded average back under
// the threshold once the collapse clears.
const routeLatencyEWMAAlpha = 0.2

// degradedRouteEWMAThresholdMs is the attempt-0 route-latency EWMA above which
// estimateRetryAfter switches from the queue-depth heuristic to distress
// scaling. Healthy routing runs ~40ms; anything over a second means the
// coordinator itself is the bottleneck.
const degradedRouteEWMAThresholdMs = 1000.0

// maxDistressRetryAfter caps the distress-scaled Retry-After (seconds).
const maxDistressRetryAfter = 60
