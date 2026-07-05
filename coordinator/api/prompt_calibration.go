package api

import (
	"strconv"
	"strings"
	"sync"
)

// Prompt-token estimate calibration for the servability context gate.
//
// estimatePromptTokens (consumer.go) approximates prompt tokens as len/4. That
// UNDERcounts real tokenization: measured prod actual/estimate ratios are p50
// 1.19, p90 ~2.1, max ~5.9 (dense code/JSON tokenizes far below 4 chars/token).
// Uncalibrated, a request whose exact prompt exceeds the model context window
// looks small enough to pass the context tier (est+max < context), gets
// dispatched, and the provider 503s with token_budget_exhausted. A conservative
// per-family multiplier nudges the gate's input up so those are caught at
// preflight (uptime-neutral 429, no dispatch). It is deliberately kept BELOW the
// observed p90 so genuinely-servable mid-size prompts are not over-rejected — the
// always-on dispatch-time deterministic stop (dispatch.go shouldStopFailover) is
// the exact backstop for everything the estimate still misses.
//
// Applied ONLY to the servability context check (see shedIfUnservable). Billing
// (estimateBillingPromptTokens upper-bounds independently) and the capacity/TTFT
// estimate are intentionally left on the raw value.

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
	return int(float64(est) * mult)
}

// SetPromptContextCalibrationFromEnv parses an override of the form
// "family:factor,family:factor" (e.g. "gpt-oss:1.3,gemma:1.15") and REPLACES the
// calibration map when at least one valid pair is present. Invalid pairs and
// factors < 1.0 are skipped (a factor below 1 would under-reject, the wrong
// direction). A blank string is a no-op (keeps the built-in default). Returns the
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
		if fam == "" || err != nil || factor < 1.0 {
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
