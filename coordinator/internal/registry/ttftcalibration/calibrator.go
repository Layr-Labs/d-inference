// Package ttftcalibration learns an online actual/raw-predicted TTFT ratio,
// preferring a warmed-up chip window over the model aggregate. Pairing against
// raw predictions avoids compounding the feedback loop. Callers record only
// warm-slot predictions and exclude speculative-race winners and cache lookups.
package ttftcalibration

import (
	"math"
	"strings"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
)

type calibrationKey struct {
	model string
	chip  string
}

// Calibrator is a leaf in the lock order: scheduler reads and settlement writes
// acquire only this lock, never a registry lock from inside the calibrator.
type Calibrator struct {
	mu      sync.RWMutex
	windows map[calibrationKey]*ratioWindow
	pending *PendingPredictions
	now     func() time.Time
}

// New retains the supplied pending owner. Nil dependencies select production
// defaults; a clock can be supplied without changing when it is sampled.
func New(pending *PendingPredictions, now func() time.Time) *Calibrator {
	if pending == nil {
		pending = NewPendingPredictions(nil)
	}
	if now == nil {
		now = time.Now
	}
	return &Calibrator{windows: make(map[calibrationKey]*ratioWindow), pending: pending, now: now}
}

// NotePrediction records the raw warm-slot estimate at reserve time.
func (c *Calibrator) NotePrediction(requestID string, attempt int, model, chip string, rawMs float64) {
	if requestID == "" || model == "" || rawMs <= 0 || math.IsNaN(rawMs) || math.IsInf(rawMs, 0) {
		return
	}
	now := c.now()
	c.mu.Lock()
	defer c.mu.Unlock()
	c.pending.Maintain(now)
	c.pending.Put(PendingID{requestID, attempt}, Prediction{Model: model, Chip: chip, RawMs: rawMs, At: now})
}

func (c *Calibrator) DiscardPrediction(requestID string, attempt int) {
	if requestID == "" {
		return
	}
	c.mu.Lock()
	c.pending.Take(PendingID{requestID, attempt})
	c.mu.Unlock()
}

// RecordActual consumes a matching prediction and returns the learned ratio
// after observing it, independent of the kill switch. Unmatched or expired
// predictions do not contribute samples.
func (c *Calibrator) RecordActual(requestID string, attempt int, actualMs float64) (float64, bool) {
	if requestID == "" || actualMs <= 0 || math.IsNaN(actualMs) || math.IsInf(actualMs, 0) {
		return 0, false
	}
	key := PendingID{requestID, attempt}
	c.mu.Lock()
	defer c.mu.Unlock()
	pred, ok := c.pending.Take(key)
	if !ok {
		return 0, false
	}
	if c.now().Sub(pred.At) > PendingTTL {
		return 0, false
	}
	ratio := actualMs / pred.RawMs
	if math.IsNaN(ratio) || math.IsInf(ratio, 0) || ratio <= 0 {
		return 0, false
	}
	c.windowLocked(pred.Model, "").add(ratio)
	if pred.Chip != "" {
		c.windowLocked(pred.Model, pred.Chip).add(ratio)
	}
	return c.learnedRatioLocked(pred.Model, pred.Chip), true
}

func (c *Calibrator) windowLocked(model, chip string) *ratioWindow {
	key := calibrationKey{model: model, chip: chip}
	w := c.windows[key]
	if w == nil {
		w = &ratioWindow{}
		c.windows[key] = w
	}
	return w
}

func (c *Calibrator) learnedRatioLocked(model, chip string) float64 {
	if chip != "" {
		if w := c.windows[calibrationKey{model: model, chip: chip}]; w != nil && w.total >= WarmupObs {
			return clampRatio(w.median)
		}
	}
	if w := c.windows[calibrationKey{model: model}]; w != nil && w.total >= WarmupObs {
		return clampRatio(w.median)
	}
	return 1.0
}

func (c *Calibrator) LearnedRatio(model, chip string) float64 {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.learnedRatioLocked(model, chip)
}

// AppliedRatio live-reads the kill switch. Learning continues while disabled.
func (c *Calibrator) AppliedRatio(model, chip string) float64 {
	v := strings.TrimSpace(env.EnvOr(env.EnvPrefix+"_TTFT_CALIBRATION", "on"))
	if strings.EqualFold(v, "off") || v == "false" || v == "0" {
		return 1.0
	}
	return c.LearnedRatio(model, chip)
}

func (c *Calibrator) Reset() {
	c.mu.Lock()
	c.windows = make(map[calibrationKey]*ratioWindow)
	c.pending.reset()
	c.mu.Unlock()
}
