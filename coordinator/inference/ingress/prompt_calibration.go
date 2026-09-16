package ingress

import (
	"math"
	"strconv"
	"strings"
	"sync"
)

var (
	calibrationMu sync.RWMutex
	// promptContextCalibration maps a model-id substring (family) to a multiplier.
	// Default is derived from observed gpt-oss ratios; tunable via
	// EIGENINFERENCE_PROMPT_CALIBRATION ("gpt-oss:1.3,gemma:1.1").
	promptContextCalibration = map[string]float64{
		"gpt-oss": 1.3,
	}
)

// calibratedContextPromptTokens returns the prompt-token estimate scaled by the
// largest matching per-family multiplier (>= 1.0). Returns est unchanged when no
// family matches or the input is non-positive. Choosing the MAX among matches is
// deterministic (map iteration order is irrelevant) and conservative.
func calibratedContextPromptTokens(model string, est int) int {
	if est <= 0 {
		return est
	}
	calibrationMu.RLock()
	mult := 1.0
	for fam, m := range promptContextCalibration {
		if m > mult && strings.Contains(model, fam) {
			mult = m
		}
	}
	calibrationMu.RUnlock()
	if mult <= 1.0 {
		return est
	}
	// Bound before converting: an out-of-range float-to-int result is
	// architecture-dependent and must never reduce a context estimate.
	scaled := float64(est) * mult
	if scaled >= float64(math.MaxInt) {
		return math.MaxInt
	}
	return int(scaled)
}

// SetPromptContextCalibrationFromEnv parses an override of the form
// "family:factor,family:factor" (e.g. "gpt-oss:1.3,gemma:1.15") and REPLACES the
// calibration map when at least one valid pair is present. Invalid pairs,
// non-finite factors, and factors < 1.0 are skipped (a factor below 1 would
// under-reject, the wrong direction). A blank string keeps the current map. Returns the
// number of pairs applied. Called once at startup from main.go.
func SetPromptContextCalibrationFromEnv(raw string) int {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return 0
	}
	next := make(map[string]float64)
	for _, pair := range strings.Split(raw, ",") {
		kv := strings.SplitN(strings.TrimSpace(pair), ":", 2)
		if len(kv) != 2 {
			continue
		}
		fam := strings.TrimSpace(kv[0])
		factor, err := strconv.ParseFloat(strings.TrimSpace(kv[1]), 64)
		if fam == "" || err != nil || math.IsNaN(factor) || math.IsInf(factor, 0) || factor < 1.0 {
			continue
		}
		next[fam] = factor
	}
	if len(next) == 0 {
		return 0
	}
	calibrationMu.Lock()
	promptContextCalibration = next
	calibrationMu.Unlock()
	return len(next)
}
