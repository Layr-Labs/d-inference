package registry

import (
	"math"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// Online per-model TTFT calibration.
//
// ttftMsFromSnapshot's constants (prefill ratio ×12, decode fallbacks) were
// measured once on an M4 Max with Qwen-7B and over-predict TTFT ~2-3× on the
// current fleet (gpt-oss-20b predicted p50 3303ms vs actual 992ms; gemma-4-26b
// 3048 vs 1638 — production inference_routes, Jun 27–Jul 3). With HARD_REJECT
// on, that bias 429s requests every eligible provider could actually have
// served. Rather than re-tune constants that will drift again, this calibrator
// learns the actual/predicted ratio ONLINE from completed requests and scales
// the live estimate by it.
//
// Design:
//
//   - Keying: per (model) and per (model, chip family). The chip-keyed ratio is
//     preferred once it has enough samples; the model-level ratio is the
//     fallback; below warm-up everywhere the ratio is 1.0 (current behavior).
//   - Robustness: the ratio is the MEDIAN of a sliding window of the most
//     recent ttftCalibrationWindowSize observations, recomputed on write and
//     cached for the (hot) read path. A cold-load outlier with a 20-30s actual
//     shifts a median by at most one rank — it cannot poison the estimate the
//     way it would poison a mean or a plain EWMA.
//   - Clamping: the APPLIED ratio is clamped to
//     [ttftCalibrationRatioMin, ttftCalibrationRatioMax] so a burst of
//     anomalous observations can never collapse the gate to zero or explode it.
//     The window stores raw ratios (clamp at apply time, not learn time) so the
//     true ratio stays observable and recovery is immediate when reality moves
//     back inside the band.
//   - Scope of the correction: only the flow portion of the estimate
//     (queued prefill + this prefill + first decode) is scaled. The cold-load
//     statePenalty (30s unknown / 20s idle_shutdown) is a load-latency proxy,
//     not a throughput estimate, and scaling it by a warm-learned ratio would
//     wrongly collapse the cold-route bias (see calibratedTTFTMs).
//     Symmetrically, only WARM-slot predictions (StateMs == 0) are learned
//     from, so cold-load time never contaminates the ratio sample.
//   - Sample hygiene: observations are joined to the RAW (pre-calibration)
//     prediction recorded at reserve time, keyed by requestID#attempt, so the
//     feedback loop converges on the absolute ratio instead of compounding.
//     Queued requests ARE included: their prediction is made at drain-reserve
//     time (after the queue wait), so the pair is unbiased. Speculative-race
//     attempts are EXCLUDED by the API-side hook (pr.UsedBackup): the race
//     winner is the min of two draws, which would bias actuals downward.
//   - Kill switch: EIGENINFERENCE_TTFT_CALIBRATION=off returns ratio 1.0 from
//     the apply path (live-read, no restart). Learning continues while off so
//     the learned ratio stays current and observable.
//
// The calibrator is package-level state (like prefillToDecodeRatio and
// ttftAdmissionMode) with its own lock: it is fed from API/settlement
// goroutines and read by the scheduler under the registry lock, and it never
// acquires any other lock, so it is a leaf in the lock order.

const (
	// ttftCalibrationWindowSize bounds the per-key sliding window of ratio
	// samples the median is computed over.
	ttftCalibrationWindowSize = 200
	// ttftCalibrationWarmupObs is the minimum observations a key needs before
	// its ratio applies; below it the applied ratio is 1.0 (current behavior).
	ttftCalibrationWarmupObs = 50
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
)

// ttftCalibrationEnabled is the live-read kill switch:
// EIGENINFERENCE_TTFT_CALIBRATION=off (or false/0) makes the apply path return
// ratio 1.0. Mirrors decodeFloorUseFleetMedian's live-env pattern.
func ttftCalibrationEnabled() bool {
	v := strings.TrimSpace(env.EnvOr(env.EnvPrefix+"_TTFT_CALIBRATION", "on"))
	return !strings.EqualFold(v, "off") && v != "false" && v != "0"
}

type ttftCalibrationKey struct {
	model string
	chip  string // "" = model-level aggregate
}

type ttftPendingPrediction struct {
	model string
	chip  string
	rawMs float64
	at    time.Time
}

// ttftRatioWindow is a fixed-size ring of actual/predicted ratio samples with a
// cached median (recomputed on write so the routing-path read is a plain load).
type ttftRatioWindow struct {
	samples []float64
	next    int
	total   int64
	median  float64
}

func (w *ttftRatioWindow) add(ratio float64) {
	if len(w.samples) < ttftCalibrationWindowSize {
		w.samples = append(w.samples, ratio)
	} else {
		w.samples[w.next] = ratio
		w.next = (w.next + 1) % ttftCalibrationWindowSize
	}
	w.total++
	w.median = medianOfSamples(w.samples)
}

func medianOfSamples(samples []float64) float64 {
	if len(samples) == 0 {
		return 1.0
	}
	sorted := make([]float64, len(samples))
	copy(sorted, samples)
	sort.Float64s(sorted)
	mid := len(sorted) / 2
	if len(sorted)%2 == 1 {
		return sorted[mid]
	}
	return (sorted[mid-1] + sorted[mid]) / 2
}

func clampTTFTCalibrationRatio(ratio float64) float64 {
	if math.IsNaN(ratio) || ratio <= 0 {
		return 1.0
	}
	if ratio < ttftCalibrationRatioMin {
		return ttftCalibrationRatioMin
	}
	if ratio > ttftCalibrationRatioMax {
		return ttftCalibrationRatioMax
	}
	return ratio
}

type ttftCalibrator struct {
	mu        sync.RWMutex
	windows   map[ttftCalibrationKey]*ttftRatioWindow
	pending   map[string]ttftPendingPrediction
	lastSweep time.Time
}

func newTTFTCalibrator() *ttftCalibrator {
	return &ttftCalibrator{
		windows: make(map[ttftCalibrationKey]*ttftRatioWindow),
		pending: make(map[string]ttftPendingPrediction),
	}
}

// ttftCalibration is the process-wide calibrator instance shared by the
// scheduler (reads + prediction recording) and the API layer (observations).
var ttftCalibration = newTTFTCalibrator()

func ttftPendingKey(requestID string, attempt int) string {
	return requestID + "#" + strconv.Itoa(attempt)
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
	if len(c.pending) >= ttftCalibrationMaxPending ||
		(len(c.pending) > ttftCalibrationSweepThreshold && now.Sub(c.lastSweep) > ttftCalibrationSweepInterval) {
		c.sweepPendingLocked(now)
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
		if w := c.windows[ttftCalibrationKey{model: model, chip: chip}]; w != nil && w.total >= ttftCalibrationWarmupObs {
			return clampTTFTCalibrationRatio(w.median)
		}
	}
	if w := c.windows[ttftCalibrationKey{model: model}]; w != nil && w.total >= ttftCalibrationWarmupObs {
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
	c.pending = make(map[string]ttftPendingPrediction)
	c.mu.Unlock()
}

// calibratedTTFTMs scales the flow portion (queued prefill + this prefill +
// first decode) of a raw ttftMsFromSnapshot estimate by the learned
// actual/predicted ratio. The cold-load statePenalty is passed through
// unscaled: it is a load-latency proxy, not part of the throughput model the
// ratio measures, and scaling it would collapse the deliberate cold-route bias
// (e.g. 30s × 0.33 ≈ 10s would let a cold box pass gates it should not).
func calibratedTTFTMs(snap routingSnapshot, rawMs float64) float64 {
	if rawMs <= 0 {
		return rawMs
	}
	ratio := ttftCalibration.appliedRatio(snap.model, snap.chipFamily)
	if ratio == 1.0 {
		return rawMs
	}
	penalty, _ := slotStatePenalty(snap.slotState)
	if penalty < 0 || penalty >= rawMs || math.IsInf(penalty, 0) {
		return rawMs
	}
	return penalty + (rawMs-penalty)*ratio
}

// RecordTTFTObservation feeds the calibrator one completed-request sample:
// the measured dispatch→first-content latency for (requestID, attempt), joined
// to the raw prediction recorded at reserve time. Called by the API layer when
// the committed attempt delivers its first content chunk. Returns the learned
// ratio now in effect for the observed (model, chip) pair and whether the
// sample was recorded (false when no matching prediction is pending).
func RecordTTFTObservation(requestID string, attempt int, actualMs float64) (float64, bool) {
	return ttftCalibration.recordActual(requestID, attempt, actualMs)
}

// TTFTCalibrationRatio returns the learned ratio the calibrator would apply
// for (model, chip): clamped median with chip→model→1.0 fallback, independent
// of the kill switch. Exposed for ops introspection and tests.
func TTFTCalibrationRatio(model, chip string) float64 {
	ttftCalibration.mu.RLock()
	defer ttftCalibration.mu.RUnlock()
	return ttftCalibration.learnedRatioLocked(model, chip)
}

// ResetTTFTCalibration clears all calibration state. Test hook.
func ResetTTFTCalibration() {
	ttftCalibration.reset()
}
