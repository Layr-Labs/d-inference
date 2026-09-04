package api

// Retry-After: one honest, jittered, single-band source.
//
// Every capacity-shaped rejection (429/503) used to compute its own
// Retry-After with its own clamp band — estimateRetryAfter's queue-depth
// heuristic [2,30] (2 s on an empty queue, else 3 s per queued request), the
// TTFT overage re-clamped to [2,30], the provider feasible_after_ms hint that
// REPLACED the estimate (clamped [2,30], so under a 60 s distress answer a
// 3 s hint emitted 3 — the #799 death loop for hinted refusals), the
// model-shed 30 s fallback that was dead code (the estimate never returned
// < 2, so an operator-shed model answered 2 s and the aggregator re-fired the
// whole model every 2 s), self_route's hard-coded 30/15 and drain's fixed
// 3 s. None was related to time-to-free-slot (a 1,000×3 pool drains a full
// queue in ~0.2 s but answered 30 s; a 5×1 pool needs > 2 min but answered
// 30 s) and none was jittered. retryAfterSeconds is now the single source:
//
//  1. Little's law from the cached warm-pool snapshot for the model (falling
//     back to the legacy queue-depth heuristic verbatim without a fresh
//     snapshot or usable capacity);
//  2. max with a caller floor (provider hint / TTFT overage / shed floor);
//  3. max with the coordinator-distress floor (distressFloorSeconds, PR #799's
//     attempt-0 route-latency EWMA scaling);
//  4. clamp to the single pre-jitter band [retryAfterMinSeconds,
//     retryAfterMaxSeconds] = [2, 60];
//  5. deterministic +0..50% jitter keyed on the coordinator-minted request id
//     (retry_after_jitter.go) — applied AFTER the clamp, so the header is at
//     most 1.5 × 60 = 90 s.
//
// estimateRetryAfter (consumer.go) is the PRE-JITTER base for a model's
// current queue depth with no caller floor; it exists for the distress
// regression tests and ops introspection, and no response writer uses it.

import (
	"math"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

const (
	// retryAfterMinSeconds keeps the legacy 2 s floor: at queuePos 0 Little's
	// law collapses to ceil(E[S]/C) = 1 s for every pool with C > E[S] — i.e.
	// for essentially every non-queue 429 — and there is no evidence a 1 s
	// answer helps, while it would double the re-fire rate on the dominant
	// rejection classes.
	retryAfterMinSeconds = 2
	retryAfterMaxSeconds = 60

	// Legacy queue-depth heuristic, kept verbatim as the no-snapshot fallback:
	// 2 s on an empty queue, else clamp(3 × queued, 2, 30).
	retryAfterLegacyPerQueuedSeconds = 3
	retryAfterLegacyMinSeconds       = 2
	retryAfterLegacyMaxSeconds       = 30

	// modelShedRetryAfterFloorSeconds is shedIfModelRejected's floor: an
	// operator-rejected model stays out of rotation for at least this long.
	modelShedRetryAfterFloorSeconds = 30

	// selfRouteOfflineRetryAfterFloorSeconds / selfRouteNotLoadedRetryAfterFloorSeconds
	// are the self-route 503 floors (machine offline / model not loaded on the
	// owner's machine), formerly hard-coded 30 and 15.
	selfRouteOfflineRetryAfterFloorSeconds   = 30
	selfRouteNotLoadedRetryAfterFloorSeconds = 15
)

// retryAfterSource labels which term of the ladder produced the answer, for
// the routing.retry_after_seconds histogram so prod can verify the source mix
// without a switch.
type retryAfterSource string

const (
	retryAfterSourceLittles  retryAfterSource = "littles"
	retryAfterSourceLegacy   retryAfterSource = "legacy"
	retryAfterSourceFloor    retryAfterSource = "floor"
	retryAfterSourceDistress retryAfterSource = "distress"
)

// retryAfterSeconds is the single Retry-After source (integer seconds, ≥ 2).
//
// Units of every term:
//   - queuePos [requests]: requests ahead of this one in the model's queue
//     (the current depth for a new arrival; the full depth on queue_full; the
//     enqueue position for a waiter that expired);
//   - E[S] = snapshot.ServiceTime [seconds/request]: service time of one
//     request on one slot (synthetic today: AssumedPromptTokens/prefillTPS +
//     AssumedCompletionTokens/serviceTPS, clamped — the honesty is bounded by
//     that model until the completion calibrator feeds it);
//   - C = snapshot.WarmProviders × snapshot.QualityConcurrency [requests]:
//     requests the warm pool serves concurrently at quality (WarmProviders
//     already applies the liveness/trust/routable gates);
//   - wait = (queuePos + 1) × E[S] / C [seconds]: time for the fleet to drain
//     queuePos + 1 requests, i.e. until a slot frees for this caller.
//
// floorSeconds is a caller-supplied lower bound in seconds (provider
// feasible_after_ms hint, TTFT overage, the model-shed floor); 0 means none.
// requestID is the jitter key (retryAfterJitterKey); empty draws a random key.
func (s *Server) retryAfterSeconds(model, requestID string, queuePos, floorSeconds int) int {
	base, source := s.retryAfterBaseSecondsWithSource(model, queuePos, floorSeconds)
	seconds := base + retryAfterJitter(base, requestID)
	s.ddHistogram("routing.retry_after_seconds", float64(seconds), []string{"source:" + string(source)})
	return seconds
}

// retryAfterBaseSeconds is retryAfterSeconds before jitter: the clamped
// max(capacity estimate, floorSeconds, distress floor).
func (s *Server) retryAfterBaseSeconds(model string, queuePos, floorSeconds int) int {
	base, _ := s.retryAfterBaseSecondsWithSource(model, queuePos, floorSeconds)
	return base
}

func (s *Server) retryAfterBaseSecondsWithSource(model string, queuePos, floorSeconds int) (int, retryAfterSource) {
	estimate, ok := 0, false
	source := retryAfterSourceLegacy
	if s != nil && s.registry != nil {
		if snap, found := s.registry.LatestWarmPoolSnapshotFor(model); found {
			estimate, ok = littlesLawRetryAfterSeconds(snap, queuePos)
		}
	}
	if ok {
		source = retryAfterSourceLittles
	} else {
		estimate = legacyRetryAfterSeconds(queuePos)
	}
	if floorSeconds > estimate {
		estimate = floorSeconds
		source = retryAfterSourceFloor
	}
	if distress := s.distressFloorSeconds(); distress > estimate {
		estimate = distress
		source = retryAfterSourceDistress
	}
	return clampRetryAfter(estimate), source
}

// littlesLawRetryAfterSeconds converts one warm-pool snapshot into the seconds
// until a slot frees for a request at queuePos: ceil((queuePos + 1) × E[S] / C).
// ok is false when the snapshot has no usable capacity (C ≤ 0 or no
// service-time estimate), so the caller falls back to the legacy heuristic.
func littlesLawRetryAfterSeconds(snap registry.WarmPoolSnapshot, queuePos int) (int, bool) {
	c := snap.WarmProviders * snap.QualityConcurrency
	if c <= 0 || snap.ServiceTime <= 0 {
		return 0, false
	}
	if queuePos < 0 {
		queuePos = 0
	}
	wait := float64(queuePos+1) * snap.ServiceTime.Seconds() / float64(c)
	return int(math.Ceil(wait)), true
}

// legacyRetryAfterSeconds is the pre-snapshot queue-depth heuristic: 2 s on
// an empty queue, else clamp(3 × queuePos, 2, 30). Kept verbatim so models
// the warm-pool controller has not observed answer exactly as before.
func legacyRetryAfterSeconds(queuePos int) int {
	if queuePos <= 0 {
		return retryAfterLegacyMinSeconds
	}
	estimate := queuePos * retryAfterLegacyPerQueuedSeconds
	if estimate < retryAfterLegacyMinSeconds {
		estimate = retryAfterLegacyMinSeconds
	}
	if estimate > retryAfterLegacyMaxSeconds {
		estimate = retryAfterLegacyMaxSeconds
	}
	return estimate
}

// distressFloorSeconds is the coordinator-distress term of the ladder (PR
// #799, 2026-09-01 congestion collapse): queue depth and fleet capacity are
// LIARS under CPU saturation — the queue is empty because nothing can reach
// it — so when the attempt-0 route-latency EWMA (noteAttempt0RouteLatency,
// anchored on ReservedAt/MediaFetchedAt) shows routing itself is degraded
// (> degradedRouteEWMAThresholdMs) the answer scales with the observed
// degradation: ceil(EWMA seconds) × 5, capped at maxDistressRetryAfter, so
// upstream backoff actually relieves pressure. 0 while routing is healthy.
func (s *Server) distressFloorSeconds() int {
	if s == nil {
		return 0
	}
	ewmaMs := s.attempt0RouteEWMAMs()
	if ewmaMs <= degradedRouteEWMAThresholdMs {
		return 0
	}
	scaled := int(math.Ceil(ewmaMs/1000)) * 5
	if scaled > maxDistressRetryAfter {
		scaled = maxDistressRetryAfter
	}
	return scaled
}

func clampRetryAfter(seconds int) int {
	if seconds < retryAfterMinSeconds {
		return retryAfterMinSeconds
	}
	if seconds > retryAfterMaxSeconds {
		return retryAfterMaxSeconds
	}
	return seconds
}
