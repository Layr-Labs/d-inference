package registry

// Capacity-derived request-queue depth.
//
// A constant per-model depth is wrong in both directions. On a model served by
// 1,000 boxes × 3 slots with a 20 s service time the fleet frees ~150 slots/s,
// so 32 queued requests are 0.2 s of buffering and any short burst overflows to
// queue_full; on a 5-box model the same 32 entries are 128 s of backlog, several
// times the first-content deadline, so positions past the first few can never
// be served and only delay their 429. Little's law sizes the depth as the
// number of requests the fleet drains within a target wait:
//
//	depth = clamp(ceil(C × queueDepthTargetWait / E[S]), queueDepthMin, queueDepthMax)
//
// where C = WarmProviders × QualityConcurrency (requests the warm pool serves
// concurrently at quality) and E[S] = ServiceTime (seconds per request), both
// from the cached warm-pool snapshot. Without a fresh snapshot the queue keeps
// its static default (RequestQueue.MaxSize). An explicit
// EIGENINFERENCE_QUEUE_MAX_DEPTH is a CEILING on the dynamic depth (prod pins
// 8, so this is inert there until an operator raises it).

import (
	"math"
	"time"
)

const (
	// queueDepthTargetWait is the queue wait the depth is sized to: well inside
	// the public first-content deadline, leaving room for routing and prefill.
	queueDepthTargetWait = 3 * time.Second
	queueDepthMin        = 8
	queueDepthMax        = 512
)

// capacityQueueDepth converts one warm-pool snapshot into a per-model queue
// depth. ok is false when the snapshot carries no usable capacity (no warm
// providers, unknown quality concurrency, or no service-time estimate).
func capacityQueueDepth(snap WarmPoolSnapshot) (depth int, ok bool) {
	c := snap.WarmProviders * snap.QualityConcurrency
	if c <= 0 || snap.ServiceTime <= 0 {
		return 0, false
	}
	raw := math.Ceil(float64(c) * queueDepthTargetWait.Seconds() / snap.ServiceTime.Seconds())
	switch {
	case raw < queueDepthMin:
		return queueDepthMin, true
	case raw > queueDepthMax:
		return queueDepthMax, true
	}
	return int(raw), true
}

// queueDepthFor is the RequestQueue.DepthFor hook wired by New: the
// capacity-derived depth for model, or 0 (keep the static default) without a
// fresh snapshot. Enqueue calls it OUTSIDE the queue lock because it takes the
// registry and warm-pool controller read locks.
func (r *Registry) queueDepthFor(model string) int {
	snap, ok := r.LatestWarmPoolSnapshotFor(model)
	if !ok {
		return 0
	}
	depth, ok := capacityQueueDepth(snap)
	if !ok {
		return 0
	}
	return depth
}
