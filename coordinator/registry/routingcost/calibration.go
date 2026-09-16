package routingcost

import (
	"strings"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// Policy.RecordTTFTObservation feeds the calibrator one completed-request sample:
// the measured dispatch→first-content latency for (requestID, attempt), joined
// to the raw prediction recorded at reserve time. Called by the API layer when
// the committed attempt delivers its first content chunk. Returns the learned
// ratio now in effect for the observed (model, chip) pair and whether the
// sample was recorded (false when no matching prediction is pending).
func (policy *Policy[Connection]) RecordTTFTObservation(requestID string, attempt int, actualMs float64) (float64, bool) {
	return policy.calibration.recordActual(requestID, attempt, actualMs)
}

// Policy.CalibrationRatio returns the learned ratio the calibrator would apply
// for (model, chip): clamped median with chip→model→1.0 fallback, independent
// of the kill switch. Exposed for ops introspection and tests.
func (policy *Policy[Connection]) CalibrationRatio(model, chip string) float64 {
	policy.calibration.mu.RLock()
	defer policy.calibration.mu.RUnlock()
	return policy.calibration.learnedRatioLocked(model, chip)
}

// Policy.ResetCalibration clears all calibration state. Test hook.
func (policy *Policy[Connection]) ResetCalibration() {
	policy.calibration.reset()
}

const (
	// ttftCalibrationWindowSize bounds the per-key sliding window of ratio
	// samples the median is computed over.
	ttftCalibrationWindowSize = 200
	// CalibrationWarmupObservations is the minimum observations a key needs before
	// its ratio applies; below it the applied ratio is 1.0 (current behavior).
	CalibrationWarmupObservations = 50
	// ttftCalibrationRatioMin/Max clamp the applied ratio so anomalies can
	// neither collapse nor explode the TTFT gate.
	ttftCalibrationRatioMin = 0.2
	ttftCalibrationRatioMax = 1.5
	// ttftCalibrationPendingTTL bounds how long an unmatched prediction
	// (request never committed content: cancel, error, speculative loser) waits
	// for its actual before being dropped.
	ttftCalibrationPendingTTL = 10 * time.Minute
	// ttftCalibrationMaxPending caps the pending-prediction join map.
	ttftCalibrationMaxPending = 8192
	// ttftCalibrationSweepThreshold / SweepInterval drive the opportunistic
	// TTL sweep: once the pending map holds more than the threshold, expired
	// entries are reaped at most once per interval — so steady-state memory
	// tracks live traffic instead of plateauing at the hard cap between
	// capacity-triggered sweeps.
	ttftCalibrationSweepThreshold = 1024
	ttftCalibrationSweepInterval  = time.Minute
	// ttftCalibrationCapacitySweepInterval lets the whole-map TTL sweep run
	// more often while the map sits AT capacity, so a sustained reserve storm
	// reclaims expired entries within seconds rather than a minute — while
	// still never sweeping on every reservation.
	ttftCalibrationCapacitySweepInterval = 5 * time.Second
	// ttftCalibrationEvictProbe bounds the per-reservation eviction scan at
	// capacity between sweeps: probe this many entries, drop the first
	// expired one, else the last probed.
	ttftCalibrationEvictProbe = 8
)

// ttftCalibrationEnabled is the live-read kill switch:
// EIGENINFERENCE_TTFT_CALIBRATION=off (or false/0) makes the apply path return
// ratio 1.0. Mirrors DecodeFloorUseFleetMedian's live-env pattern.
func ttftCalibrationEnabled() bool {
	v := strings.TrimSpace(env.EnvOr(env.EnvPrefix+"_TTFT_CALIBRATION", "on"))
	return !strings.EqualFold(v, "off") && v != "false" && v != "0"
}

type ttftCalibrator struct {
	mu        sync.RWMutex
	windows   map[ttftCalibrationKey]*ttftRatioWindow
	pending   map[ttftPendingID]ttftPendingPrediction
	lastSweep time.Time
}

func newTTFTCalibrator() *ttftCalibrator {
	return &ttftCalibrator{
		windows: make(map[ttftCalibrationKey]*ttftRatioWindow),
		pending: make(map[ttftPendingID]ttftPendingPrediction),
	}
}

func (c *ttftCalibrator) windowLocked(model, chip string) *ttftRatioWindow {
	key := ttftCalibrationKey{model: model, chip: chip}
	w := c.windows[key]
	if w == nil {
		w = &ttftRatioWindow{}
		c.windows[key] = w
	}
	return w
}

// learnedRatioLocked is the clamped median for (model, chip) with hierarchical
// fallback: the chip-keyed window once it clears warm-up, else the model-level
// window once it clears warm-up, else 1.0. Caller holds c.mu (read or write).
func (c *ttftCalibrator) learnedRatioLocked(model, chip string) float64 {
	if chip != "" {
		if w := c.windows[ttftCalibrationKey{model: model, chip: chip}]; w != nil && w.total >= CalibrationWarmupObservations {
			return clampTTFTCalibrationRatio(w.median)
		}
	}
	if w := c.windows[ttftCalibrationKey{model: model}]; w != nil && w.total >= CalibrationWarmupObservations {
		return clampTTFTCalibrationRatio(w.median)
	}
	return 1.0
}

// appliedRatio is the ratio the live estimate is scaled by: the learned ratio,
// or 1.0 when the kill switch is off.
func (c *ttftCalibrator) appliedRatio(model, chip string) float64 {
	if !ttftCalibrationEnabled() {
		return 1.0
	}
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.learnedRatioLocked(model, chip)
}

func (c *ttftCalibrator) reset() {
	c.mu.Lock()
	c.windows = make(map[ttftCalibrationKey]*ttftRatioWindow)
	c.pending = make(map[ttftPendingID]ttftPendingPrediction)
	c.mu.Unlock()
}
