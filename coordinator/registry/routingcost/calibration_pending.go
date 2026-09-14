package routingcost

import (
	"math"
	"time"
)

type ttftPendingPrediction struct {
	model string
	chip  string
	rawMs float64
	at    time.Time
}

// ttftPendingID identifies a reserved attempt's pending prediction. A struct
// key (vs requestID+"#"+attempt) is built without allocating on every
// reservation and cannot alias across ids containing the delimiter.
type ttftPendingID struct {
	requestID string
	attempt   int
}

func ttftPendingKey(requestID string, attempt int) ttftPendingID {
	return ttftPendingID{requestID: requestID, attempt: attempt}
}

// notePrediction records the RAW (pre-calibration) warm-slot TTFT estimate for
// a reserved attempt so a later first-content observation can be joined to it.
func (c *ttftCalibrator) notePrediction(requestID string, attempt int, model, chip string, rawMs float64) {
	if requestID == "" || model == "" || rawMs <= 0 || math.IsNaN(rawMs) || math.IsInf(rawMs, 0) {
		return
	}
	now := time.Now()
	c.mu.Lock()
	defer c.mu.Unlock()
	// The TTL sweep walks the whole map, so it is rate-limited: once per
	// ttftCalibrationSweepInterval above the threshold, and once per (shorter)
	// ttftCalibrationCapacitySweepInterval while AT capacity. Between sweeps a
	// full map (a reserve storm whose attempts never reach first content — the
	// exact retry-cascade shape) frees one slot with a bounded probe instead of
	// walking all ttftCalibrationMaxPending entries under this global lock on
	// every reservation (that walk was ~20% of a fleet-scale reservation). The
	// map stays bounded either way.
	atCapacity := len(c.pending) >= ttftCalibrationMaxPending
	sinceSweep := now.Sub(c.lastSweep)
	if len(c.pending) > ttftCalibrationSweepThreshold &&
		(sinceSweep > ttftCalibrationSweepInterval ||
			(atCapacity && sinceSweep > ttftCalibrationCapacitySweepInterval)) {
		c.sweepPendingLocked(now)
	}
	if len(c.pending) >= ttftCalibrationMaxPending {
		c.evictOneLocked(now)
	}
	c.pending[ttftPendingKey(requestID, attempt)] = ttftPendingPrediction{
		model: model,
		chip:  chip,
		rawMs: rawMs,
		at:    now,
	}
}

// discardPrediction removes a reserve-time prediction when provider-specific
// preparation confirms that the concrete attempt will participate in reusable
// cache lookup. It is safe when no warm-slot prediction was recorded.
func (c *ttftCalibrator) discardPrediction(requestID string, attempt int) {
	if requestID == "" {
		return
	}
	c.mu.Lock()
	delete(c.pending, ttftPendingKey(requestID, attempt))
	c.mu.Unlock()
}

// evictOneLocked frees one slot in a full map with bounded work: it probes up
// to ttftCalibrationEvictProbe entries (map order — effectively random),
// deletes the first EXPIRED one it sees, and only when none of the probed
// entries has expired deletes the last probed (possibly live) entry. Caller
// holds c.mu.
func (c *ttftCalibrator) evictOneLocked(now time.Time) {
	var last ttftPendingID
	probed := 0
	for k, p := range c.pending {
		if now.Sub(p.at) > ttftCalibrationPendingTTL {
			delete(c.pending, k)
			return
		}
		last = k
		probed++
		if probed >= ttftCalibrationEvictProbe {
			break
		}
	}
	if probed > 0 {
		delete(c.pending, last)
	}
}

// sweepPendingLocked drops expired predictions; if the map is still at
// capacity afterwards (pathological reserve flood with no commits), arbitrary
// entries are dropped so the map stays bounded. Caller holds c.mu.
func (c *ttftCalibrator) sweepPendingLocked(now time.Time) {
	c.lastSweep = now
	for k, p := range c.pending {
		if now.Sub(p.at) > ttftCalibrationPendingTTL {
			delete(c.pending, k)
		}
	}
	for k := range c.pending {
		if len(c.pending) < ttftCalibrationMaxPending {
			break
		}
		delete(c.pending, k)
	}
}

// recordActual joins a measured first-content latency to the pending
// prediction for (requestID, attempt) and feeds the actual/predicted ratio
// into the model-level and (model, chip) windows. Returns the learned ratio
// the calibrator would now apply for that pair (post-clamp, post-warm-up,
// independent of the kill switch) and whether an observation was recorded.
func (c *ttftCalibrator) recordActual(requestID string, attempt int, actualMs float64) (float64, bool) {
	if requestID == "" || actualMs <= 0 || math.IsNaN(actualMs) || math.IsInf(actualMs, 0) {
		return 0, false
	}
	key := ttftPendingKey(requestID, attempt)
	c.mu.Lock()
	defer c.mu.Unlock()
	pred, ok := c.pending[key]
	if !ok {
		return 0, false
	}
	delete(c.pending, key)
	if time.Since(pred.at) > ttftCalibrationPendingTTL {
		return 0, false
	}
	ratio := actualMs / pred.rawMs
	if math.IsNaN(ratio) || math.IsInf(ratio, 0) || ratio <= 0 {
		return 0, false
	}
	c.windowLocked(pred.model, "").add(ratio)
	if pred.chip != "" {
		c.windowLocked(pred.model, pred.chip).add(ratio)
	}
	return c.learnedRatioLocked(pred.model, pred.chip), true
}
